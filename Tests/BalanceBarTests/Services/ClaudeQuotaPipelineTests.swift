import Foundation
import XCTest
@testable import BalanceBar

/// Offline transport for the pipeline: no Keychain, network or home directory is touched.
private final class PipelineStubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var data = Data()
        var headers: [String: String] = [:]
        var error: URLError?
    }

    private static let lock = NSLock()
    private static var reply = Reply()
    private static var requests = 0

    static func reset(_ reply: Reply = Reply()) {
        lock.lock(); self.reply = reply; requests = 0; lock.unlock()
    }

    static func set(_ reply: Reply) {
        lock.lock(); self.reply = reply; lock.unlock()
    }

    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let reply = Self.reply
        Self.lock.unlock()
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MutableCredentialReader: OfficialQuotaCredentialReading {
    private let lock = NSLock()
    private var token: String?
    init(token: String?) { self.token = token }
    func set(_ value: String?) { lock.lock(); token = value; lock.unlock() }
    func codexAccessToken() -> String? { nil }
    func codexAccountProfile() -> CodexAccountProfile? { nil }
    func claudeAccessToken() -> String? { lock.lock(); defer { lock.unlock() }; return token }
}

private final class PipelineClock: SchedulerClock {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(by interval: TimeInterval) { lock.lock(); value.addTimeInterval(interval); lock.unlock() }
}

/// Blocks the first account-file read until released, to prove startup stays off the caller's thread.
private final class GatedConfigurationReader: AccountConfigurationReading {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let data: Data
    init(data: Data) { self.data = data }
    func readData(from url: URL) throws -> Data {
        entered.signal()
        release.wait()
        return data
    }
}

/// Records confirmation-retry delays and runs them only when the test fires them.
private final class ManualRetryTimer: SchedulerTimer {
    private(set) var delays: [TimeInterval] = []
    private var works: [() -> Void] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        delays.append(delay)
        works.append(work)
    }

    func fireFirst() { guard !works.isEmpty else { return }; works.removeFirst()() }
}

private final class LockedLines {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ line: String) { lock.lock(); values.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Controllable stand-in for Claude Code's per-process session registry.
private final class StubSessionStarts: ClaudeSessionStartLookup {
    var starts: [String: Date] = [:]
    func startedAt(sessionID: String) -> Date? { starts[sessionID] }
}

final class ClaudeQuotaPipelineTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private var clock: PipelineClock!
    private var reader: MutableCredentialReader!
    private var official: OfficialQuotaClient!
    private var pipelines: [ClaudeQuotaPipeline] = []
    private var lastIdentity: ClaudeAccountIdentityProvider!
    private var lastInbox: SnapshotInbox?
    private var lastStatusLineSessions: StubSessionStarts?
    private var lastStatusLineSocketURL: URL?
    private let diagnosticLines = LockedLines()

    private static let start = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
    /// Reset times of the stubbed official `usage` response above.
    private static let usageFiveReset = Date(timeIntervalSince1970: 1_700_017_200) // 2023-11-15T03:00:00Z
    private static let usageSevenReset = Date(timeIntervalSince1970: 1_700_438_400) // 2023-11-20T00:00:00Z
    /// The seven-day reset of the `nearReset` stub (2023-11-21T00:00:00Z).
    private static let nearResetSevenReset = Date(timeIntervalSince1970: 1_700_000_000 + 524_800)
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let usage = Data(#"{"five_hour":{"utilization":23,"resets_at":"2023-11-15T03:00:00Z"},"seven_day":{"utilization":41,"resets_at":"2023-11-20T00:00:00Z"}}"#.utf8)
    private static let nextCycle = Data(#"{"five_hour":{"utilization":2,"resets_at":"2023-11-15T08:00:00Z"},"seven_day":{"utilization":42,"resets_at":"2023-11-20T00:00:00Z"}}"#.utf8)
    /// Old-cycle data whose five-hour reset lies only a minute ahead, so a test can cross it
    /// while still inside Claude V1's five-minute minimum interval.
    private static let nearReset = Data(#"{"five_hour":{"utilization":23,"resets_at":1700000060},"seven_day":{"utilization":41,"resets_at":"2023-11-21T00:00:00Z"}}"#.utf8)

    /// Claude V1 timing with a short coalescing window for deterministic stub round trips.
    private var claudeV1TestConfiguration: FetchSchedulerConfiguration {
        var configuration = FetchSchedulerConfiguration.claudeV1
        configuration.coalescingWindow = 0.02
        return configuration
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-ClaudePipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PipelineStubProtocol.self]
        session = URLSession(configuration: configuration)
        PipelineStubProtocol.reset(.init(data: Self.usage))
        clock = PipelineClock(Self.start)
        reader = MutableCredentialReader(token: "token-1")
        official = OfficialQuotaClient(session: session, credentialReader: reader, now: { [clock] in clock!.now })
        try writeAccount("account-a", email: "a@example.com")
    }

    override func tearDown() {
        pipelines.removeAll()
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
        if let socket = lastStatusLineSocketURL {
            try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
        }
        lastStatusLineSocketURL = nil
        lastStatusLineSessions = nil
        super.tearDown()
    }

    private var configurationURL: URL { directory.appendingPathComponent("claude.json") }

    private func writeAccount(_ uuid: String, email: String) throws {
        let object = ["oauthAccount": ["accountUuid": uuid, "emailAddress": email, "organizationUuid": "org"]]
        try JSONSerialization.data(withJSONObject: object).write(to: configurationURL, options: .atomic)
    }

    private func makePipeline(
        reader configurationReader: AccountConfigurationReading = DefaultAccountConfigurationReader(),
        realtimeTracker: ClaudeRealtimeTracker? = nil,
        configuration: FetchSchedulerConfiguration? = nil,
        confirmationTimer: SchedulerTimer = DispatchSchedulerTimer(),
        statusLineEnabled: Bool = false,
        withTestStatusLine: Bool = false,
        withInbox: Bool = false,
        sourceValidity: @escaping () -> ClaudeSourceValidity = { .defaults }
    ) -> ClaudeQuotaPipeline {
        let identityQueue = DispatchQueue(label: "test.pipeline.identity")
        let identity = ClaudeAccountIdentityProvider(
            configurationURL: configurationURL, reader: configurationReader,
            workQueue: identityQueue, coalescingInterval: 0.02, now: { [clock] in clock!.now })
        lastIdentity = identity
        var resolved = configuration ?? FetchSchedulerConfiguration()
        resolved.coalescingWindow = 0.02
        let tracker: ClaudeRealtimeTracker?
        let statusLineSource: ClaudeStatusLineSource?
        if withTestStatusLine {
            tracker = realtimeTracker ?? ClaudeRealtimeTracker(now: { [clock] in clock!.now })
            let sessions = StubSessionStarts()
            lastStatusLineSessions = sessions
            // The listener chmods its own directory, so give the socket a dedicated one.
            lastStatusLineSocketURL = URL(fileURLWithPath: "/tmp/bb596-\(UUID().uuidString.prefix(6))/s.sock")
            statusLineSource = ClaudeStatusLineSource(
                accountProvider: identity, tracker: tracker!, socketURL: lastStatusLineSocketURL!,
                sessionStarts: sessions, sessionStaleInterval: 7_200, endedSessionCheckInterval: 7_200,
                now: { [clock] in clock!.now })
        } else {
            tracker = realtimeTracker
            statusLineSource = nil
        }
        let inbox = withInbox
            ? SnapshotInbox(
                inboxDirectory: inboxDirectoryURL, identity: identity,
                configuration: SnapshotInboxConfiguration(io: QuotaIOConfiguration(watchCoalescingInterval: 0.05)),
                now: { [clock] in clock!.now })
            : nil
        lastInbox = inbox
        let pipeline = ClaudeQuotaPipeline(
            client: official, identity: identity, identityQueue: identityQueue,
            stateDirectory: directory.appendingPathComponent("state", isDirectory: true),
            schedulerClock: clock, confirmationTimer: confirmationTimer, schedulerConfiguration: resolved,
            realtimeTracker: tracker,
            statusLineSource: statusLineSource,
            snapshotInbox: inbox,
            statusLineEnabled: statusLineEnabled,
            sourceValidity: sourceValidity,
            now: { [clock] in clock!.now },
            diagnostics: { [diagnosticLines] message, _ in diagnosticLines.append(message) })
        pipelines.append(pipeline)
        return pipeline
    }

    /// Writes a BalanceBar Mod snapshot for the account `email` into the pipeline's inbox.
    private func placeModSnapshot(
        five: Double,
        seven: Double,
        observedAt: Date,
        fiveReset: Date? = nil,
        sevenReset: Date? = nil,
        omitResets: Bool = false,
        email: String = "a@example.com",
        emailHash: String? = nil,
        as name: String = "balancebar-mod-test.json"
    ) throws {
        var fiveHour: [String: Any] = ["used_percentage": five]
        var sevenHour: [String: Any] = ["used_percentage": seven]
        if !omitResets {
            fiveHour["resets_at"] = Self.isoFormatter.string(from: fiveReset ?? Self.usageFiveReset)
            sevenHour["resets_at"] = Self.isoFormatter.string(from: sevenReset ?? Self.usageSevenReset)
        }
        let object: [String: Any] = [
            "updated_at": Self.isoFormatter.string(from: observedAt),
            "five_hour": fiveHour,
            "seven_day": sevenHour,
            "source": "balancebar-mod",
            "account": ["email_hash": emailHash ?? SnapshotInbox.emailHash(email)],
        ]
        try FileManager.default.createDirectory(at: inboxDirectoryURL, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object)
            .write(to: inboxDirectoryURL.appendingPathComponent(name), options: .atomic)
    }

    private func pollUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private var inboxDirectoryURL: URL { directory.appendingPathComponent("inbox", isDirectory: true) }

    private func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while PipelineStubProtocol.requestCount < count, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(PipelineStubProtocol.requestCount, count, file: file, line: line)
    }

    private func waitForState(
        _ pipeline: ClaudeQuotaPipeline, timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line,
        where predicate: (ClaudeQuotaState) -> Bool
    ) -> ClaudeQuotaState? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pipeline.waitUntilIdle()
            if let state = pipeline.latestState, predicate(state) { return state }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("pipeline never reached the expected state; latest: \(String(describing: pipeline.latestState))", file: file, line: line)
        return nil
    }

    private func quiet(_ pipeline: ClaudeQuotaPipeline) {
        pipeline.waitUntilIdle()
        Thread.sleep(forTimeInterval: 0.2)
        pipeline.waitUntilIdle()
    }

    // MARK: Startup

    func testStartupBuildsEngineAndLoadsAccountOffTheCallingThread() throws {
        let gate = GatedConfigurationReader(data: try Data(contentsOf: configurationURL))
        let pipeline = makePipeline(reader: gate)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        // The gated reader has not been released yet, so no state can exist if start/request did not block on file IO.
        XCTAssertNil(pipeline.latestState)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        gate.release.signal()
        gate.release.signal()
        let state = waitForState(pipeline) { !$0.windows.isEmpty }
        XCTAssertEqual(state?.windows.map(\.remaining), [77, 59])
    }

    func testOfficialReadStopsBeingLiveAfterTenMinutes() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status == .realtime(.oauthAPI, at: Self.start) })
        clock.advance(by: ClaudeSourceValidity.defaults.oauth + 1)
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.latestState?.status, .official(at: Self.start, source: .oauthAPI),
                       "an old official read is no longer live; the slot shows its age and source")
    }

    func testFirstLaunchReadsOnceAndPublishesOfficialStatus() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        let state = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        XCTAssertEqual(state.status, .realtime(.oauthAPI, at: Self.start), "a fresh official read is live, labelled with its source")
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.updatedAt, Self.start)
        XCTAssertEqual(state.windows.map(\.label), [tr(.keyResponseParsers5HourQuota), tr(.keyResponseParsers7DayQuota)])
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1)
    }

    // MARK: Restart

    func testRestartShowsLastOfficialValuesWithoutARequestAndDropsAnotherAccount() throws {
        let first = makePipeline()
        first.requestFetch(reason: .initial)
        XCTAssertNotNil(waitForState(first) { !$0.windows.isEmpty })
        first.flush()
        pipelines.removeAll()

        let sameAccount = makePipeline()
        sameAccount.start()
        let restored = try XCTUnwrap(waitForState(sameAccount) { !$0.windows.isEmpty })
        XCTAssertEqual(restored.windows.map(\.remaining), [77, 59])
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "a restart alone does not read the server")
        sameAccount.flush()
        pipelines.removeAll()

        try writeAccount("account-b", email: "b@example.com")
        let otherAccount = makePipeline()
        otherAccount.start()
        let empty = try XCTUnwrap(waitForState(otherAccount) { _ in true })
        XCTAssertTrue(empty.windows.isEmpty, "another account never inherits the previous account's numbers")
    }

    func testRateLimitCooldownSurvivesRestart() throws {
        PipelineStubProtocol.set(.init(status: 429, headers: ["Retry-After": "1800"]))
        let first = makePipeline()
        first.requestFetch(reason: .initial)
        let limited = try XCTUnwrap(waitForState(first) { $0.failure == .rateLimited })
        XCTAssertNil(limited.updatedAt)
        let until = try XCTUnwrap(first.manualRefreshBlockedUntil())
        XCTAssertEqual(until.timeIntervalSince(Self.start), 1_800, accuracy: 1)
        pipelines.removeAll()

        PipelineStubProtocol.set(.init(data: Self.usage))
        let restarted = makePipeline()
        restarted.requestFetch(reason: .initial)
        quiet(restarted)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "the restarted app waits out the server's cooldown")
        XCTAssertNotNil(restarted.manualRefreshBlockedUntil())
        clock.advance(by: 1_801)
        XCTAssertNil(restarted.manualRefreshBlockedUntil())
        restarted.requestFetch(reason: .manual)
        XCTAssertNotNil(waitForState(restarted) { !$0.windows.isEmpty })
    }

    // MARK: Credentials and accounts

    func testUnauthorizedPausesUntilTheCredentialChangesForTheSameAccount() throws {
        PipelineStubProtocol.set(.init(status: 401))
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        XCTAssertNotNil(waitForState(pipeline) { $0.failure == .unauthorized })
        clock.advance(by: 600)
        pipeline.requestFetch(reason: .scheduled)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "an unchanged rejected credential is not retried")

        // Same account, refreshed token: reads resume.
        PipelineStubProtocol.set(.init(data: Self.usage))
        reader.set("token-2")
        clock.advance(by: 3) // the credential probe is shared for two seconds
        pipeline.requestFetch(reason: .scheduled)
        let state = waitForState(pipeline) { !$0.windows.isEmpty }
        XCTAssertNil(state?.failure)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 2)
    }

    /// Issue #562: after a 401 the pause outlives a restart, and a manual refresh used to be skipped
    /// without any visible state.
    func testManualRefreshDuringPersistedUnauthorizedPauseShowsLoginExpiredAndRecoversWithTheCredential() throws {
        PipelineStubProtocol.set(.init(status: 401))
        let first = makePipeline()
        first.requestFetch(reason: .initial)
        XCTAssertNotNil(waitForState(first) { $0.failure == .unauthorized })
        pipelines.removeAll()

        let restarted = makePipeline()
        restarted.requestFetch(reason: .manual)
        quiet(restarted)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "the paused credential is not retried")
        XCTAssertEqual(restarted.latestState?.failure, .unauthorized, "the skipped manual refresh must be visible")
        XCTAssertEqual(restarted.manualRefreshNotice(), .loginExpired)
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("skip=unauthorizedPaused") && $0.contains("reasons=manual") },
                      "the skip reason is logged: \(diagnosticLines.all)")

        PipelineStubProtocol.set(.init(data: Self.usage))
        reader.set("token-2")
        clock.advance(by: 3)
        restarted.requestFetch(reason: .manual)
        let state = waitForState(restarted) { !$0.windows.isEmpty }
        XCTAssertNil(state?.failure)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 2)
        guard case let .recentResult(until)? = restarted.manualRefreshNotice() else {
            return XCTFail("the login-expired hint is gone once a read succeeds; got \(String(describing: restarted.manualRefreshNotice()))")
        }
        XCTAssertEqual(until.timeIntervalSince(clock.now), 60, accuracy: 1)
    }

    func testManualRefreshDuringCooldownShowsTheWaitAndLogsTheSkip() throws {
        PipelineStubProtocol.set(.init(status: 429, headers: ["Retry-After": "1800"]))
        let first = makePipeline()
        first.requestFetch(reason: .initial)
        XCTAssertNotNil(waitForState(first) { $0.failure == .rateLimited })
        pipelines.removeAll()

        let restarted = makePipeline()
        restarted.requestFetch(reason: .manual)
        quiet(restarted)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1)
        XCTAssertEqual(restarted.latestState?.failure, .rateLimited)
        guard case let .rateLimited(until)? = restarted.manualRefreshNotice() else {
            return XCTFail("expected a rate-limit notice, got \(String(describing: restarted.manualRefreshNotice()))")
        }
        XCTAssertEqual(until.timeIntervalSince(Self.start), 1_800, accuracy: 1)
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("skip=cooldown") && $0.contains("cooldown_remaining=") })
    }

    func testManualRefreshRightAfterASuccessIsSkippedWithAJustRefreshedNotice() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        XCTAssertNotNil(waitForState(pipeline) { !$0.windows.isEmpty })
        guard case let .recentResult(until)? = pipeline.manualRefreshNotice() else {
            return XCTFail("expected a recent-result notice, got \(String(describing: pipeline.manualRefreshNotice()))")
        }
        XCTAssertEqual(until.timeIntervalSince(Self.start), 60, accuracy: 1)

        clock.advance(by: 10)
        pipeline.requestFetch(reason: .manual)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "a read inside the manual window is not repeated")
        XCTAssertNil(pipeline.latestState?.failure, "a just-refreshed skip is a hint, not a failure")
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("skip=recentResult") })

        clock.advance(by: 61)
        XCTAssertNil(pipeline.manualRefreshNotice())
        pipeline.requestFetch(reason: .manual)
        waitForRequests(2)
    }

    func testManualRefreshNoticeReportsLocalFreshWhenNativeWindowsAreFresh() {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker)
        tracker.recordTrustedObservation(window: .fiveHour, observedAt: Self.start, epoch: .initial)
        tracker.recordTrustedObservation(window: .sevenDay, observedAt: Self.start, epoch: .initial)
        XCTAssertEqual(pipeline.manualRefreshNotice(), .localFresh)
    }

    func testManualRefreshNoticeIgnoresLocalDataOlderThanTheManualWindowEvenIfStillValid() {
        let tracker = ClaudeRealtimeTracker(
            validity: { ClaudeSourceValidity(oauth: 600, statusLine: 600, mod: 600) },
            now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker)
        tracker.recordTrustedObservation(window: .fiveHour, observedAt: Self.start, epoch: .initial)
        tracker.recordTrustedObservation(window: .sevenDay, observedAt: Self.start, epoch: .initial)
        clock.advance(by: 30)
        XCTAssertEqual(pipeline.manualRefreshNotice(), .localFresh, "inside the manual window the refresh is skipped")
        clock.advance(by: 90)
        XCTAssertNotNil(tracker.lastTrustedRealtimeObservationAt, "the data still counts as live for the status")
        XCTAssertNil(pipeline.manualRefreshNotice(), "but a manual refresh would query the official API, so no skip notice")
    }

    func testSameAccountCredentialRefreshKeepsEpochAndScope() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        let first = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        reader.set("token-2")
        clock.advance(by: 180)
        pipeline.requestFetch(reason: .scheduled)
        let second = try XCTUnwrap(waitForState(pipeline) { $0.updatedAt == Self.start.addingTimeInterval(180) })
        XCTAssertEqual(first.accountEpoch, second.accountEpoch)
        XCTAssertEqual(first.accountScope, second.accountScope)
        XCTAssertFalse((first.accountScope ?? "").contains("a@example.com"), "the scope is an opaque hash")
    }

    /// Issue #584: the state carries the normalized account key that scopes
    /// quota prediction evidence, and it follows the signed-in account.
    func testPredictionAccountKeyIsNormalizedAndTracksTheSignedInAccount() throws {
        XCTAssertNil(ClaudeQuotaPipeline.predictionAccountKey(for: nil))
        XCTAssertNil(ClaudeQuotaPipeline.predictionAccountKey(
            for: AccountIdentity(stableID: "id", email: "  ", idSource: .emailFallback)))
        XCTAssertEqual(ClaudeQuotaPipeline.predictionAccountKey(
            for: AccountIdentity(stableID: "id", email: " A@Example.COM ", idSource: .accountUUID)), "a@example.com")

        // The evidence journal is keyed by the stable account ID, not the
        // email: same-email Claude accounts must stay isolated (PR #587 review).
        XCTAssertNil(ClaudeQuotaPipeline.predictionEvidenceKey(for: nil))
        XCTAssertNil(ClaudeQuotaPipeline.predictionEvidenceKey(
            for: AccountIdentity(stableID: "claude:acc-1:org", email: " ", idSource: .accountUUID)))
        let sameEmailA = AccountIdentity(stableID: "claude:acc-1:org", email: "a@example.com", idSource: .accountUUID)
        let sameEmailB = AccountIdentity(stableID: "claude:acc-2:org", email: "a@example.com", idSource: .accountUUID)
        XCTAssertEqual(ClaudeQuotaPipeline.predictionEvidenceKey(for: sameEmailA), "claude:acc-1:org")
        XCTAssertEqual(ClaudeQuotaPipeline.predictionEvidenceKey(for: sameEmailB), "claude:acc-2:org")
        XCTAssertEqual(ClaudeQuotaPipeline.predictionAccountKey(for: sameEmailA),
                       ClaudeQuotaPipeline.predictionAccountKey(for: sameEmailB), "the menu key stays email-based")

        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        let first = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        XCTAssertEqual(first.predictionAccountKey, "a@example.com")
        XCTAssertEqual(first.predictionEvidenceKey, "claude:account-a:org")

        PipelineStubProtocol.set(.init(data: Self.nextCycle))
        try writeAccount("account-b", email: "B@Example.com")
        let second = try XCTUnwrap(waitForState(pipeline) {
            $0.accountEpoch != first.accountEpoch && !$0.windows.isEmpty
        })
        XCTAssertEqual(second.predictionAccountKey, "b@example.com", "the key is lowercased and never reused across accounts")
        XCTAssertEqual(second.predictionEvidenceKey, "claude:account-b:org")
    }

    func testAccountSwitchClearsOldValuesBumpsEpochAndReadsTheNewAccount() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        let first = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 180) // one request token refills
        PipelineStubProtocol.set(.init(data: Self.nextCycle))
        try writeAccount("account-b", email: "b@example.com")
        let second = try XCTUnwrap(waitForState(pipeline) { $0.accountEpoch != first.accountEpoch && !$0.windows.isEmpty })
        XCTAssertNotEqual(first.accountScope, second.accountScope)
        XCTAssertEqual(second.windows.first?.remaining, 98, "the new account shows only its own reading")
        XCTAssertEqual(PipelineStubProtocol.requestCount, 2)
    }

    // MARK: Failures keep the last official values

    func testNetworkFailureKeepsValuesAndRecoversOnTheNextRead() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        PipelineStubProtocol.set(.init(error: URLError(.notConnectedToInternet)))
        clock.advance(by: 180)
        pipeline.requestFetch(reason: .scheduled)
        let failed = try XCTUnwrap(waitForState(pipeline) { $0.failure != nil })
        guard case .transport(let possibleProxy, _)? = failed.failure else { return XCTFail("expected a transport failure") }
        XCTAssertTrue(possibleProxy, "connection failures carry the proxy hint")
        XCTAssertEqual(failed.windows.map(\.remaining), [77, 59], "offline keeps the last official numbers")
        XCTAssertEqual(failed.status, .error(at: Self.start, source: .oauthAPI))

        PipelineStubProtocol.set(.init(data: Self.usage))
        clock.advance(by: 360)
        pipeline.requestFetch(reason: .scheduled)
        let recovered = try XCTUnwrap(waitForState(pipeline) { $0.failure == nil && $0.updatedAt == Self.start.addingTimeInterval(540) })
        XCTAssertEqual(recovered.status, .realtime(.oauthAPI, at: Self.start.addingTimeInterval(540)))
    }

    func testMissingCredentialsAndInvalidResponsesAreReportedWithoutLosingValues() throws {
        reader.set(nil)
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        XCTAssertNotNil(waitForState(pipeline) { $0.failure == .missingCredentials })
        XCTAssertEqual(PipelineStubProtocol.requestCount, 0, "no token means no request")

        reader.set("token-1")
        PipelineStubProtocol.set(.init(data: Data("{}".utf8)))
        clock.advance(by: 180)
        pipeline.requestFetch(reason: .manual)
        XCTAssertNotNil(waitForState(pipeline) { $0.failure == .invalidResponse })
    }

    // MARK: Reset handling

    func testPassingTheResetTimeRequestsConfirmationAndANewCycleIsConfirmed() throws {
        var notified: [Snapshot] = []
        let lock = NSLock()
        let pipeline = makePipeline()
        pipeline.onNotification = { snapshot in lock.lock(); notified.append(snapshot); lock.unlock() }
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        // 03:00Z has passed: the window waits for a fresh official reading.
        clock.advance(by: 5 * 3_600)
        PipelineStubProtocol.set(.init(data: Self.nextCycle))
        pipeline.tick()
        waitForRequests(2)
        let confirmed = try XCTUnwrap(waitForState(pipeline) { $0.windows.first?.remaining == 98 })
        XCTAssertEqual(confirmed.status, .realtime(.oauthAPI, at: clock.now))
        lock.lock()
        XCTAssertEqual(notified.last?.officialQuotaWindows.first?.remaining, 98, "the confirmed new cycle reaches the notification rules")
        lock.unlock()
    }

    func testStaleReadingAfterTheResetTimeStaysPendingUntilConfirmed() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 5 * 3_600)
        PipelineStubProtocol.set(.init(data: Self.usage)) // server still reports the old cycle
        pipeline.tick()
        waitForRequests(2)
        let state = try XCTUnwrap(waitForState(pipeline) {
            if case .resetPending = $0.status { return true }
            return false
        })
        XCTAssertEqual(state.windows.first?.remaining, 100,
                       "an old-cycle reading is not a confirmation; the card shows the window as already reset")
    }

    /// Issue #580: crossing the reset deadline inside the automatic minimum interval still
    /// dispatches the official confirmation immediately instead of skipping it.
    func testResetConfirmationDispatchesImmediatelyDespiteRecentSuccess() throws {
        PipelineStubProtocol.set(.init(data: Self.nearReset))
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration)
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        clock.advance(by: 120) // past the five-hour deadline, inside the 5-minute minimum interval
        PipelineStubProtocol.set(.init(data: Self.nextCycle))
        pipeline.tick()
        waitForRequests(2)

        let confirmed = try XCTUnwrap(waitForState(pipeline) { $0.windows.first?.remaining == 98 })
        XCTAssertEqual(confirmed.status, .realtime(.oauthAPI, at: clock.now), "the new cycle is confirmed without waiting")
    }

    /// Issue #580: while the reset waits for official confirmation, a manual refresh reaches
    /// the server instead of being silently skipped by the recent-result window.
    func testManualRefreshDuringPendingResetReachesTheServerAndExplainsItself() throws {
        PipelineStubProtocol.set(.init(data: Self.nearReset))
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration)
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        clock.advance(by: 120)
        // The confirmation request fails to parse, so no success updates the suppression window.
        PipelineStubProtocol.set(.init(data: Data("not json".utf8)))
        pipeline.tick()
        waitForRequests(2)
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.display.state, .resetPendingConfirmation)

        // 121 s clears the failure backoff while staying inside Claude V1's 5-minute manual window.
        clock.advance(by: 121)
        XCTAssertEqual(pipeline.manualRefreshNotice(), .awaitingResetConfirmation,
                       "past the backoff, the menu explains the pending confirmation")
        PipelineStubProtocol.set(.init(data: Self.nextCycle))
        pipeline.requestFetch(reason: .manual)
        waitForRequests(3)
        let confirmed = try XCTUnwrap(waitForState(pipeline) { $0.windows.first?.remaining == 98 })
        XCTAssertEqual(confirmed.status, .realtime(.oauthAPI, at: clock.now))
    }

    /// Issue #580: an unconfirmed reset keeps retrying the official read on a 1 → 2 minute
    /// cadence until the new cycle arrives.
    func testPendingResetRetriesConfirmationUntilTheNewCycleArrives() throws {
        PipelineStubProtocol.set(.init(data: Self.nearReset))
        let retryTimer = ManualRetryTimer()
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration, confirmationTimer: retryTimer)
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        clock.advance(by: 120)
        PipelineStubProtocol.set(.init(data: Data("not json".utf8)))
        pipeline.tick()
        waitForRequests(2)
        quiet(pipeline)
        XCTAssertEqual(retryTimer.delays, [60], "the first retry is armed one minute out")

        clock.advance(by: 121) // past the failure backoff
        PipelineStubProtocol.set(.init(data: Self.nextCycle))
        retryTimer.fireFirst()
        waitForRequests(3)
        let confirmed = try XCTUnwrap(waitForState(pipeline) { $0.windows.first?.remaining == 98 })
        XCTAssertEqual(confirmed.status, .realtime(.oauthAPI, at: clock.now))
        XCTAssertEqual(retryTimer.delays, [60, 120], "the cadence backs off while confirmation is pending")
    }

    /// A plain failed read never locks the manual refresh: the menu offers a retry instead of
    /// a countdown.
    func testManualRefreshNoticeDoesNotBlockAfterAPlainFailure() throws {
        PipelineStubProtocol.set(.init(data: Self.nearReset))
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration)
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        clock.advance(by: 120)
        PipelineStubProtocol.set(.init(data: Data("not json".utf8)))
        pipeline.tick()
        waitForRequests(2)
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.display.state, .resetPendingConfirmation)
        XCTAssertEqual(pipeline.manualRefreshNotice(), .awaitingResetConfirmation,
                       "only the pending-confirmation hint remains; no failure countdown")
    }

    /// Issue #580 review: an exhausted request budget must be explained too, not offered
    /// as an immediate confirmation.
    func testManualRefreshNoticeExplainsExhaustedTokens() throws {
        var configuration = FetchSchedulerConfiguration()
        configuration.coalescingWindow = 0.02
        configuration.manualRefreshWindow = 10
        configuration.tokenRefillInterval = 600
        let pipeline = makePipeline(configuration: configuration)
        pipeline.requestFetch(reason: .initial) // first read: manual cost, tokens 3 → 2
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        clock.advance(by: 11)
        pipeline.requestFetch(reason: .manual) // tokens 2 → 1
        waitForRequests(2)
        quiet(pipeline) // the stub completes asynchronously; drain before advancing the fake clock
        clock.advance(by: 11)
        pipeline.requestFetch(reason: .manual) // tokens 1 → 0
        waitForRequests(3)
        quiet(pipeline)

        clock.advance(by: 11)
        pipeline.requestFetch(reason: .manual) // suppressed by insufficient tokens
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 3)
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("skip=insufficientTokens") })
        guard case let .outOfTokens(until)? = pipeline.manualRefreshNotice() else {
            return XCTFail("expected an out-of-tokens notice, got \(String(describing: pipeline.manualRefreshNotice()))")
        }
        XCTAssertEqual(until.timeIntervalSince(Self.start), 600, accuracy: 1,
                       "one token refills ten minutes after the epoch anchor")
    }
    /// A window past its reset with no newer reading shows as already reset (untouched, full
    /// window length) instead of the stale reading; the card projects "now + length" for display.
    func testCardWindowShowsAlreadyResetWhilePending() {
        let display = QuotaWindowDisplay(
            kind: .fiveHour, usedPercentage: 70, resetsAt: Self.start.addingTimeInterval(-60),
            isEstimated: false, state: .resetPendingConfirmation, hoverTextKey: "quota.merge.hover.reset_pending_confirmation")
        let model = QuotaDisplayModel(
            windows: [display], isEstimated: false,
            state: .resetPendingConfirmation, hoverTextKey: "quota.merge.hover.reset_pending_confirmation")
        let windows = ClaudeQuotaPipeline.cardWindows(from: model, now: Self.start)
        XCTAssertEqual(windows.map(\.kind), [.fiveHour])
        XCTAssertEqual(windows.first?.remaining, 100)
        XCTAssertEqual(windows.first?.reset, ResponseParsingSupport.resetDescription(5 * 3_600, now: Self.start))
        XCTAssertNil(windows.first?.resetAt, "no server reset yet; the card projects now + 5h when drawing")
        let projected = windows.first?.projectingIdleReset(now: Self.start)
        XCTAssertEqual(projected?.resetAt, Self.start.addingTimeInterval(5 * 3_600))

        // Outside the pending state an unknown reset stays unknown.
        let inProgress = QuotaWindowDisplay(
            kind: .fiveHour, usedPercentage: 70, resetsAt: Self.start.addingTimeInterval(-60),
            isEstimated: false, state: .inProgress, hoverTextKey: "quota.merge.hover.in_progress")
        let plain = ClaudeQuotaPipeline.cardWindows(
            from: QuotaDisplayModel(windows: [inProgress], isEstimated: false, state: .inProgress, hoverTextKey: "quota.merge.hover.in_progress"),
            now: Self.start)
        XCTAssertNil(plain.first?.reset)
    }

    // MARK: Manual-test fixtures (PR "如何人工测试" steps 6 and 7)

    func testDocumentedCooldownFileDisablesReadsAfterRestart() throws {
        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let json: [String: Any] = ["cooldownUntil": Self.start.timeIntervalSince1970 + 3_600,
                                   "consecutiveRateLimitBackoffs": 1, "isUnauthorizedPaused": false]
        try JSONSerialization.data(withJSONObject: json).write(to: stateDirectory.appendingPathComponent("claude-fetch-scheduler.json"))
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 0, "no request while the cooldown lasts")
        XCTAssertEqual(try XCTUnwrap(pipeline.manualRefreshBlockedUntil()).timeIntervalSince(Self.start), 3_600, accuracy: 1)
    }

    func testDocumentedResetTimeEditMakesTheWindowPendingAfterRestart() throws {
        let first = makePipeline()
        first.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(first) { !$0.windows.isEmpty })
        first.flush()
        pipelines.removeAll()

        // Same edit as the documented python snippet: every `resetsAt` becomes ten minutes ago, as
        // seconds since 2001-01-01 (JSONEncoder's Date format).
        let file = directory.appendingPathComponent("state/claude-quota-merge.json")
        let reference = Self.start.timeIntervalSince1970 - 978_307_200 - 600
        func fix(_ value: Any) -> Any {
            if var dictionary = value as? [String: Any] {
                for (key, inner) in dictionary {
                    dictionary[key] = key == "resetsAt" && inner is NSNumber ? reference : fix(inner)
                }
                return dictionary
            }
            if let array = value as? [Any] { return array.map(fix) }
            return value
        }
        let edited = fix(try JSONSerialization.jsonObject(with: Data(contentsOf: file)))
        try JSONSerialization.data(withJSONObject: edited).write(to: file)

        let restarted = makePipeline()
        restarted.start()
        restarted.tick()
        let pending = try XCTUnwrap(waitForState(restarted) {
            if case .resetPending = $0.status { return true }
            return false
        })
        XCTAssertEqual(pending.display.window(for: .fiveHour)?.state, .resetPendingConfirmation)
        // The next read of the new cycle confirms the reset and clears the pending state.
        PipelineStubProtocol.set(.init(data: Self.nextCycle))
        clock.advance(by: 5 * 3_600)
        restarted.tick()
        let confirmed = try XCTUnwrap(waitForState(restarted) { $0.windows.first?.remaining == 98 })
        XCTAssertEqual(confirmed.status, .realtime(.oauthAPI, at: clock.now))
    }

    // MARK: - Mod snapshots through the inbox (Issue #596)

    private func mergeWindowKeys(_ pipeline: ClaudeQuotaPipeline) -> Set<String> {
        Set((pipeline.mergeStateForDiagnostics?.windows ?? [:]).keys)
    }

    func testAccountSwitchNotifiesTheModSnapshotEventSink() throws {
        final class EventBox {
            private let lock = NSLock()
            private var values: [ClaudeQuotaPipeline.ModSnapshotEvent] = []
            func append(_ value: ClaudeQuotaPipeline.ModSnapshotEvent) { lock.lock(); values.append(value); lock.unlock() }
            func snapshot() -> [ClaudeQuotaPipeline.ModSnapshotEvent] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let events = EventBox()
        let pipeline = makePipeline(withInbox: true)
        pipeline.modSnapshotEventSink = { events.append($0) }
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        let first = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        XCTAssertFalse(events.snapshot().contains { $0.kind == .accountChanged })

        try writeAccount("account-b", email: "b@example.com")
        _ = try XCTUnwrap(waitForState(pipeline) { $0.accountEpoch != first.accountEpoch && !$0.windows.isEmpty })
        XCTAssertTrue(
            pollUntil { events.snapshot().contains { $0.kind == .accountChanged } },
            "an account switch must tell the settings entry to drop the old account's evidence")
    }

    func testModSnapshotEventSinkReceivesAcceptancesAndInboxRejections() throws {
        final class EventBox {
            private let lock = NSLock()
            private var values: [ClaudeQuotaPipeline.ModSnapshotEvent] = []
            func append(_ value: ClaudeQuotaPipeline.ModSnapshotEvent) { lock.lock(); values.append(value); lock.unlock() }
            func snapshot() -> [ClaudeQuotaPipeline.ModSnapshotEvent] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let events = EventBox()
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.modSnapshotEventSink = { events.append($0) }
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        XCTAssertTrue(events.snapshot().isEmpty, "official reads never produce Mod snapshot events")

        // A changed snapshot on the official cycle is accepted: one processed event per window.
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        XCTAssertTrue(pollUntil { events.snapshot().count >= 2 })
        let acceptances = events.snapshot().prefix(2)
        for (event, window) in zip(acceptances, [QuotaWindowKind.fiveHour, .sevenDay]) {
            XCTAssertEqual(event.kind, .processed(accepted: true))
            XCTAssertEqual(event.window, window)
            XCTAssertEqual(event.observedAt, Self.start.addingTimeInterval(310))
        }

        // A snapshot from a foreign account is rejected before emission and reported once.
        try placeModSnapshot(
            five: 30, seven: 50, observedAt: Self.start.addingTimeInterval(320),
            emailHash: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            as: "foreign.json")
        XCTAssertTrue(pollUntil { events.snapshot().count >= 3 })
        XCTAssertEqual(events.snapshot().count, 3, "no extra events beyond two acceptances and one rejection")
        XCTAssertEqual(events.snapshot()[2].kind, .rejected(reason: .accountEmailHashMismatch))
        XCTAssertNil(events.snapshot()[2].window)
    }

    func testModSnapshotDisplaysAndSuppressesAutomaticReadsWhileFresh() throws {
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, withTestStatusLine: true, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        // A changed snapshot on the official cycle is displayed and counts as evidence.
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        let realtime = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(realtime.display.window(for: .fiveHour)?.usedPercentage, 25)
        XCTAssertEqual(realtime.display.window(for: .sevenDay)?.usedPercentage, 42)

        // Past the official minimum interval, a scheduled read is skipped as realtime-fresh.
        pipeline.requestFetch(reason: .scheduled)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1)
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("skip=realtimeSourceFresh") })

        // Past the manual window and still fresh, a manual refresh is served by the free path
        // and the notice reports the local source.
        clock.advance(by: 61)
        XCTAssertEqual(pipeline.manualRefreshNotice(), .localFresh)
        pipeline.requestFetch(reason: .manual)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1)

        // A same-value snapshot rewrite is a whole-snapshot replay: the inbox does not even
        // emit it, so it can neither refresh the display nor extend freshness. Had it been
        // emitted as evidence, the tracker would stay fresh until start+486 and both the
        // notice and the scheduled read below would disagree.
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(372))
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertTrue(pollUntil { inbox.queue.sync { inbox.suppressedReplayCount } >= 1 })
        clock.advance(by: 65) // start+431; the changed snapshot's evidence expired at start+430
        XCTAssertNil(pipeline.manualRefreshNotice(), "the same-value replay must not be local-fresh evidence")
        pipeline.requestFetch(reason: .scheduled)
        waitForRequests(2)
    }

    func testModSnapshotOnAnUnrelatedCycleIsRejectedAfterOfficialBaseline() throws {
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        try placeModSnapshot(
            five: 90, seven: 95, observedAt: Self.start.addingTimeInterval(1),
            fiveReset: Self.start.addingTimeInterval(100_000), sevenReset: Self.start.addingTimeInterval(200_000))
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertTrue(pollUntil {
            inbox.adapters.contains { adapter in
                if case let .degraded(reason) = adapter.health,
                   reason.contains("cycle_unverified_against_official") { return true }
                return false
            }
        }, "a snapshot that cannot be tied to the official cycle is rejected as a whole")
        let state = try XCTUnwrap(pipeline.latestState)
        XCTAssertEqual(state.display.window(for: .fiveHour)?.usedPercentage, 23)
        XCTAssertEqual(state.display.window(for: .sevenDay)?.usedPercentage, 41)
        XCTAssertEqual(state.status, .realtime(.oauthAPI, at: Self.start))
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "rejected Mod data must not suppress the official read")
        XCTAssertEqual(mergeWindowKeys(pipeline), ["five_hour", "seven_day"])
    }

    func testModReadingBelowTheOfficialValueWithinToleranceStillCountsAsLiveEvidence() throws {
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, withTestStatusLine: true, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        // The official API says 41 for the 7-day window; the Mod rounds it down to 40. The display
        // never moves backwards, yet the Mod window is evidence that the local source is alive.
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 40, observedAt: Self.start.addingTimeInterval(310))
        let realtime = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(realtime.display.window(for: .fiveHour)?.usedPercentage, 25)
        XCTAssertEqual(realtime.display.window(for: .sevenDay)?.usedPercentage, 41, "the display never moves backwards")

        pipeline.requestFetch(reason: .scheduled)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "both windows are fresh local evidence")
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("skip=realtimeSourceFresh") })
    }

    func testRescannedOldModSnapshotDoesNotCreateFreshness() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(5))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        // Later the same file is rewritten byte for byte (inbox rescan): the whole-snapshot
        // replay is suppressed upstream and the freshness measured from the snapshot's own
        // observation time has long expired, so nothing turns fresh.
        clock.advance(by: 300)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(5))
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertTrue(pollUntil { inbox.queue.sync { inbox.suppressedReplayCount } >= 1 })
        XCTAssertNil(pipeline.manualRefreshNotice(), "a rescanned old snapshot is not local-fresh")
        pipeline.requestFetch(reason: .scheduled)
        waitForRequests(2)
        // The resumed official read recalibrates the display, as it always may.
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 23 })
    }

    func testRejectedSnapshotDoesNotBecomeTheReplayBaseline() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        let inbox = try XCTUnwrap(lastInbox)

        // A snapshot from a concurrent session that the merge engine rejects (usage would
        // move backwards) must not overwrite the replay baseline.
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(5))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        clock.advance(by: 305)
        try placeModSnapshot(five: 24, seven: 41, observedAt: Self.start.addingTimeInterval(310))
        XCTAssertTrue(pollUntil {
            self.diagnosticLines.all.contains { $0.contains("reason=usage_decreased_within_cycle") }
        })

        // The previously adopted values arrive again: they are a replay of the adopted
        // baseline, not new evidence, and must not re-extend freshness. Had the rejected
        // snapshot become the baseline, this write would be emitted and adopted again.
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(315))
        XCTAssertTrue(pollUntil { inbox.queue.sync { inbox.suppressedReplayCount } >= 1 })
        clock.advance(by: 75) // start+380; the adopted evidence expired at start+125
        XCTAssertNil(pipeline.manualRefreshNotice(), "a rejected snapshot must not enable a freshness extension")
        pipeline.requestFetch(reason: .scheduled)
        waitForRequests(2)
    }

    func testSnapshotRejectedBeforeTheOfficialBaselineDoesNotSuppressTheSameValueLater() throws {
        // Startup race: the inbox scan delivers a snapshot before any official read exists,
        // so the merge engine rejects it. It must not become the replay baseline either.
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(1))
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertEqual(inbox.queue.sync { inbox.suppressedReplayCount }, 0)

        // The same values measured again, now with the official baseline in place: fresh
        // evidence, displayed instead of being filtered as a replay of a rejected snapshot.
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(10))
        let attributed = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(attributed.display.window(for: .fiveHour)?.usedPercentage, 25)
    }

    func testModSupersetWindowsAndForeignInboxSourcesNeverReachTheClaudeEngine() throws {
        try FileManager.default.createDirectory(at: inboxDirectoryURL, withIntermediateDirectories: true)
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        // Mod superset: the extra windows must not create engine state or reset confirmations.
        let superset: [String: Any] = [
            "updated_at": Self.isoFormatter.string(from: Self.start.addingTimeInterval(1)),
            "five_hour": ["used_percentage": 90, "resets_at": Self.isoFormatter.string(from: Self.start.addingTimeInterval(100_000))],
            "seven_day": ["used_percentage": 95, "resets_at": Self.isoFormatter.string(from: Self.start.addingTimeInterval(200_000))],
            "source": "balancebar-mod",
            "account": ["email_hash": SnapshotInbox.emailHash("a@example.com")],
            "windows": [
                ["kind": "five_hour", "used_percentage": 90],
                ["kind": "seven_day", "used_percentage": 95],
                ["kind": "sonnet_context", "used_percentage": 12],
                ["kind": "extra_usage", "used_percentage": 35],
            ],
        ]
        try JSONSerialization.data(withJSONObject: superset)
            .write(to: inboxDirectoryURL.appendingPathComponent("balancebar-mod-superset.json"))
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertTrue(pollUntil {
            // The official cycle is known, so the superset snapshot is rejected wholesale by the
            // cycle verification and never displays.
            inbox.adapters.contains { adapter in
                if case let .degraded(reason) = adapter.health,
                   reason.contains("cycle_unverified_against_official") { return true }
                return false
            }
        })

        // An unrelated inbox source with plausible values must be ignored entirely.
        let foreign: [String: Any] = [
            "updated_at": Self.isoFormatter.string(from: Self.start.addingTimeInterval(1)),
            "five_hour": ["used_percentage": 24, "resets_at": Self.isoFormatter.string(from: Self.usageFiveReset)],
            "source": "some-other-tool",
        ]
        try JSONSerialization.data(withJSONObject: foreign)
            .write(to: inboxDirectoryURL.appendingPathComponent("foreign.json"))
        quiet(pipeline)
        XCTAssertEqual(mergeWindowKeys(pipeline), ["five_hour", "seven_day"])
        let state = try XCTUnwrap(pipeline.latestState)
        XCTAssertEqual(state.display.window(for: .fiveHour)?.usedPercentage, 23)
        XCTAssertEqual(state.display.window(for: .sevenDay)?.usedPercentage, 41)
    }

    func testAccountSwitchRejectsThePreviousAccountModSnapshots() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(5))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        try writeAccount("account-b", email: "b@example.com")
        // The switch clears the card and reads the new account officially.
        _ = try XCTUnwrap(waitForState(pipeline) {
            $0.display.window(for: .fiveHour)?.usedPercentage == 23
                && $0.display.window(for: .fiveHour)?.state == .inProgress
        })
        // The old account's snapshot cannot prove it belongs to account B.
        try placeModSnapshot(five: 30, seven: 43, observedAt: Self.start.addingTimeInterval(10))
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertTrue(pollUntil { inbox.adapters.contains { adapter in
            if case let .degraded(reason) = adapter.health, reason.contains("does not match") { return true }
            return false
        } }, "the foreign snapshot should be rejected by the inbox")
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 23)

        // Account B's own snapshot is attributed and displayed.
        try placeModSnapshot(five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(20), email: "b@example.com")
        let attributed = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(attributed.display.window(for: .fiveHour)?.usedPercentage, 24)
    }

    func testConcurrentModSessionUsageRegressionIsRejected() throws {
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        try placeModSnapshot(five: 26, seven: 42, observedAt: Self.start.addingTimeInterval(5))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 26 })

        // A concurrent session wrote an older measurement later: the display never regresses.
        try placeModSnapshot(five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(10))
        XCTAssertTrue(pollUntil {
            self.diagnosticLines.all.contains { $0.contains("reason=usage_decreased_within_cycle") }
        })
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 26)

        // Growth is still accepted.
        try placeModSnapshot(five: 27, seven: 42, observedAt: Self.start.addingTimeInterval(15))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 27 })
    }

    func testCrossSourceNativeRegressionIsRejectedInBothDirections() throws {
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, statusLineEnabled: true,
            withTestStatusLine: true, withInbox: true)
        lastStatusLineSessions?.starts["s1"] = Self.start.addingTimeInterval(1)
        lastStatusLineSessions?.starts["s2"] = Self.start.addingTimeInterval(2)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        // statusLine moves the display up; a lower Mod snapshot must not pull it back.
        deliverStatusLine(session: "s1", five: 26, seven: 42, at: Self.start.addingTimeInterval(5))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 26 })
        try placeModSnapshot(five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(10))
        XCTAssertTrue(pollUntil {
            self.diagnosticLines.all.contains { $0.contains("reason=usage_decreased_within_cycle") }
        })
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 26)

        // The Mod takes over at the same value (a replay merges, the source flips), and a
        // lower value from another statusLine session must not pull the display back either.
        clock.advance(by: 10)
        try placeModSnapshot(five: 26, seven: 42, observedAt: Self.start.addingTimeInterval(15))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.updatedAt == Self.start.addingTimeInterval(15) })
        deliverStatusLine(session: "s2", five: 25, seven: 42, at: Self.start.addingTimeInterval(20))
        XCTAssertTrue(pollUntil {
            let lines = self.diagnosticLines.all
            return lines.filter { $0.contains("reason=usage_decreased_within_cycle") }.count >= 2
        })
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 26)
    }

    func testModSnapshotUnverifiableAgainstOfficialCycleFallsBackToOfficial() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        let inbox = try XCTUnwrap(lastInbox)

        // The snapshot only carries an email hash; a different cycle cannot be tied to this
        // account's official calibration, so the whole snapshot is rejected.
        try placeModSnapshot(
            five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(5),
            fiveReset: Self.start.addingTimeInterval(50_000), sevenReset: Self.start.addingTimeInterval(90_000))
        XCTAssertTrue(pollUntil { inbox.queue.sync { inbox.unverifiedSnapshotRejections } >= 1 })
        XCTAssertEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 23)

        // Mixed cycles: one matching window must not carry a snapshot whose other window
        // fails verification (no A's 5h next to B's 7d).
        try placeModSnapshot(
            five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(6),
            sevenReset: Self.start.addingTimeInterval(90_000))
        XCTAssertTrue(pollUntil { inbox.queue.sync { inbox.unverifiedSnapshotRejections } >= 2 })
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 23)

        // Without reset times the cycle cannot be verified either.
        try placeModSnapshot(five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(7), omitResets: true)
        XCTAssertTrue(pollUntil { inbox.queue.sync { inbox.unverifiedSnapshotRejections } >= 3 })
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 23)

        // The same values on the official cycle are attributed and displayed.
        try placeModSnapshot(five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(10))
        let attributed = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(attributed.display.window(for: .fiveHour)?.usedPercentage, 24)
    }

    func testStatusLinePartialWindowUpdateKeepsRealtime() throws {
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, statusLineEnabled: true,
            withTestStatusLine: true, withInbox: true)
        lastStatusLineSessions?.starts["s1"] = Self.start.addingTimeInterval(1)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        // statusLine re-renders report both windows whenever any of them changed; a window
        // whose integer percentage did not move is still part of that fresh report.
        deliverStatusLine(session: "s1", five: 24, seven: 41, at: Self.start.addingTimeInterval(5))
        let state = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(state.display.window(for: .fiveHour)?.usedPercentage, 24)
        XCTAssertEqual(state.display.window(for: .sevenDay)?.usedPercentage, 41)
    }

    func testFreshStatusLineOverridesUnauthorizedErrorStatus() throws {
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, statusLineEnabled: true,
            withTestStatusLine: true, withInbox: true)
        lastStatusLineSessions?.starts["s1"] = Self.start.addingTimeInterval(1)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        PipelineStubProtocol.set(.init(status: 401))
        clock.advance(by: 600)
        pipeline.requestFetch(reason: .manual)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.failure == .unauthorized })

        deliverStatusLine(session: "s1", five: 24, seven: 41, at: clock.now)
        let state = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(state.failure, .unauthorized, "the official read is still paused; only the card status recovers")

        // Past the real-time freshness (the default 2 minutes) the reading is no longer valid
        // evidence, so the failure matters again and the slot shows how old the data is.
        clock.advance(by: ClaudeSourceValidity.defaults.statusLine + 5)
        pipeline.tick()
        pipeline.waitUntilIdle()
        guard case .error(_, .statusLine?) = pipeline.latestState?.status else {
            return XCTFail("expected error once local data went stale, got \(String(describing: pipeline.latestState?.status))")
        }
    }

    func testLongerLocalValidityKeepsFailedReadsFromTurningTheCardRed() throws {
        var validity = ClaudeSourceValidity.defaults
        validity.statusLine = 600
        let tracker = ClaudeRealtimeTracker(validity: { validity }, now: { [clock] in clock!.now })
        let pipeline = makePipeline(
            realtimeTracker: tracker, configuration: claudeV1TestConfiguration, statusLineEnabled: true,
            withTestStatusLine: true, withInbox: true, sourceValidity: { validity })
        lastStatusLineSessions?.starts["s1"] = Self.start.addingTimeInterval(1)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        PipelineStubProtocol.set(.init(status: 401))
        clock.advance(by: 600)
        pipeline.requestFetch(reason: .manual)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.failure == .unauthorized })
        deliverStatusLine(session: "s1", five: 24, seven: 41, at: clock.now)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        clock.advance(by: 400) // well past the default 2 minutes, inside the chosen 10
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertTrue(pipeline.latestState?.status.isNativeRealtime ?? false, "the chosen validity keeps the slot live")
    }

    func testSourceValidityChoiceDrivesTheStatusImmediately() throws {
        var validity = ClaudeSourceValidity.defaults
        validity.statusLine = 300
        let tracker = ClaudeRealtimeTracker(validity: { validity }, now: { [clock] in clock!.now })
        let pipeline = makePipeline(
            realtimeTracker: tracker, configuration: claudeV1TestConfiguration, statusLineEnabled: true,
            withTestStatusLine: true, withInbox: true, sourceValidity: { validity })
        lastStatusLineSessions?.starts["s1"] = Self.start.addingTimeInterval(1)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        let at = Self.start.addingTimeInterval(5)
        deliverStatusLine(session: "s1", five: 24, seven: 41, at: at)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        clock.advance(by: 200) // 200 s old: stale by default, live under the chosen 5 minutes
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.latestState?.status, .realtime(.statusLine, at: at))

        validity.statusLine = 60
        pipeline.sourceValidityChanged()
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.latestState?.status, .official(at: at, source: .statusLine),
                       "shortening the validity takes effect without waiting for new data")
    }

    func testOAuthValidityControlsHowLongAnOfficialReadStaysLive() throws {
        var validity = ClaudeSourceValidity.defaults
        validity.oauth = 1_800
        let pipeline = makePipeline(sourceValidity: { validity })
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status == .realtime(.oauthAPI, at: Self.start) })
        clock.advance(by: 1_200)
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.latestState?.status, .realtime(.oauthAPI, at: Self.start))
        clock.advance(by: 700)
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.latestState?.status, .official(at: Self.start, source: .oauthAPI))
    }

    func testLongerModValidityKeepsSkippingOfficialReadsPastTheDefaultFreshness() throws {
        var validity = ClaudeSourceValidity.defaults
        validity.mod = 600
        let tracker = ClaudeRealtimeTracker(validity: { validity }, now: { [clock] in clock!.now })
        let pipeline = makePipeline(
            realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true,
            sourceValidity: { validity })
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        clock.advance(by: 250) // 250 s after the snapshot: past the default 2 minutes
        pipeline.requestFetch(reason: .scheduled)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "the chosen validity still suppresses the official read")
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("skip=realtimeSourceFresh") })

        validity.mod = 120
        pipeline.sourceValidityChanged()
        quiet(pipeline)
        pipeline.requestFetch(reason: .scheduled)
        waitForRequests(2)
    }

    func testStatusLineReadingBecomesAgeAndSourceOnceItIsNoLongerLive() throws {
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, statusLineEnabled: true,
            withTestStatusLine: true, withInbox: true)
        lastStatusLineSessions?.starts["s1"] = Self.start.addingTimeInterval(1)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        let at = Self.start.addingTimeInterval(5)
        deliverStatusLine(session: "s1", five: 24, seven: 41, at: at)
        let live = try XCTUnwrap(waitForState(pipeline) { $0.status.liveSource == .statusLine })
        XCTAssertEqual(live.status, .realtime(.statusLine, at: at))

        // Past the two-minute freshness the card keeps the values but says how old they are and who
        // produced them, instead of a bare clock time.
        clock.advance(by: 125)
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.latestState?.status, .official(at: at, source: .statusLine))
    }

    /// A Mod reading that moved backwards inside the cycle is rejected for that window only. The other
    /// window is still updated in real time, so the slot must not fall back to the stale/orange look.
    func testModReadingKeepsTheSlotLiveWhenOneWindowIsRejected() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        try placeModSnapshot(five: 24, seven: 40, observedAt: Self.start.addingTimeInterval(5))
        let state = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 24 })
        XCTAssertEqual(state.display.window(for: .sevenDay)?.usedPercentage, 41, "the lower seven-day value is rejected")
        XCTAssertEqual(state.status.liveSource, .mod)

        // Two minutes after that reading the slot shows its age and source.
        clock.advance(by: 130)
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.latestState?.status.liveSource, nil)
        XCTAssertEqual(pipeline.latestState?.status, .official(at: Self.start.addingTimeInterval(5), source: .mod))
    }

    func testModPartialWindowChangeKeepsWholeSnapshotAsEvidence() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        try placeModSnapshot(five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(5))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        // One window changed, the other repeated its value: like statusLine's whole-payload
        // semantics, the whole snapshot is fresh evidence, so both windows are re-recorded.
        clock.advance(by: 10)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(15))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 25 })
        // The unchanged window's evidence moved with this snapshot (start+15 + 120s); a
        // per-window replay rule would have left it at start+5 + 120s and expired by now.
        clock.advance(by: 115) // start+125
        XCTAssertTrue(pipeline.latestState?.status.isNativeRealtime ?? false)
    }

    func testCompleteModNextCycleConfirmsPendingResetAndShowsLiveWithoutOfficialConfirmation() throws {
        PipelineStubProtocol.set(.init(data: Self.nearReset))
        let retryTimer = ManualRetryTimer()
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, confirmationTimer: retryTimer, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 120)
        pipeline.tick()
        waitForRequests(2)

        // The Mod's snapshot carries the next five-hour cycle with its reset time. Its seven-day
        // window still describes the current official cycle, so the snapshot passes the
        // snapshot-atomic cycle verification and establishes the new cycle by itself.
        try placeModSnapshot(
            five: 2, seven: 42, observedAt: Self.start.addingTimeInterval(125),
            fiveReset: Self.start.addingTimeInterval(10_000), sevenReset: Self.nearResetSevenReset)
        let live = try XCTUnwrap(waitForState(pipeline) {
            $0.display.window(for: .fiveHour)?.usedPercentage == 2 && $0.status.isNativeRealtime
        })
        XCTAssertEqual(live.display.window(for: .fiveHour)?.state, .inProgress)
        XCTAssertNil(pipeline.mergeStateForDiagnostics?.windows[QuotaWindowKind.fiveHour.rawValue]?.pendingResetOf,
                     "no waiting for official confirmation")
    }

    func testModReadingContradictingTheOfficialValueIsRejectedAndLoggedAsAConflict() throws {
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        // Official five-hour value is 23; a Mod reading of 10 is far below the rounding tolerance.
        try placeModSnapshot(five: 10, seven: 42, observedAt: Self.start.addingTimeInterval(5))
        XCTAssertTrue(pollUntil {
            self.diagnosticLines.all.contains {
                $0.contains("claude source conflict") && $0.contains("reason=lower_than_displayed")
            }
        })
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 23)
        let conflict = try XCTUnwrap(diagnosticLines.all.first { $0.contains("claude source conflict") })
        XCTAssertFalse(conflict.contains("@"), "the conflict line carries no account data")
    }

    func testStatusLineAndModCoexistenceKeepsTheLatestTrustedValues() throws {
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, statusLineEnabled: true,
            withTestStatusLine: true, withInbox: true)
        lastStatusLineSessions?.starts["s1"] = Self.start.addingTimeInterval(1)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        deliverStatusLine(session: "s1", five: 24, seven: 42, at: Self.start.addingTimeInterval(5))
        let native = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(native.display.window(for: .fiveHour)?.usedPercentage, 24)
        XCTAssertEqual(native.status.liveSource, .statusLine, "the slot names the source of the newest reading")

        // A newer Mod snapshot takes over the display without summing with statusLine data.
        try placeModSnapshot(five: 25, seven: 43, observedAt: Self.start.addingTimeInterval(10))
        let mod = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 25 })
        XCTAssertEqual(mod.status.liveSource, .mod)
        XCTAssertEqual(mod.display.window(for: .sevenDay)?.usedPercentage, 43)

        // A later statusLine render wins again; only one source's values are ever shown.
        deliverStatusLine(session: "s1", five: 27, seven: 42, at: Self.start.addingTimeInterval(20))
        let latest = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 27 })
        XCTAssertEqual(latest.status.liveSource, .statusLine)

        // An older Mod snapshot cannot regress the display.
        try placeModSnapshot(five: 24, seven: 43, observedAt: Self.start.addingTimeInterval(8), as: "balancebar-mod-old.json")
        XCTAssertTrue(pollUntil {
            self.diagnosticLines.all.contains { $0.contains("reason=usage_decreased_within_cycle") }
        })
        XCTAssertEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 27)
    }

    // MARK: Source timeline (Issue #619)

    func testSourceTimelineRecordsOfficialReadsAndFailureRuns() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        XCTAssertEqual(pipeline.sourceTimeline.snapshot().readings.map(\.source), [.oauthAPI])
        XCTAssertEqual(pipeline.sourceTimeline.snapshot().readings.first?.observedAt, Self.start)

        PipelineStubProtocol.set(.init(error: URLError(.notConnectedToInternet)))
        clock.advance(by: 180)
        pipeline.requestFetch(reason: .scheduled)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.failure != nil })
        XCTAssertEqual(pipeline.sourceTimeline.snapshot().failures, [
            ClaudeSourceTimeline.FailureRun(start: Self.start.addingTimeInterval(180), end: nil, kind: .network)
        ])

        PipelineStubProtocol.set(.init(data: Self.usage))
        clock.advance(by: 360)
        pipeline.requestFetch(reason: .scheduled)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.failure == nil && $0.updatedAt == Self.start.addingTimeInterval(540) })
        let snapshot = pipeline.sourceTimeline.snapshot()
        XCTAssertEqual(snapshot.failures.first?.end, Self.start.addingTimeInterval(540), "the next adopted read ends the run")
        XCTAssertEqual(snapshot.readings.map(\.observedAt), [Self.start, Self.start.addingTimeInterval(540)])
        XCTAssertEqual(snapshot.readings.last?.expiresAt, Self.start.addingTimeInterval(540 + ClaudeSourceValidity.defaults.oauth))
    }

    func testSourceTimelineRecordsOnlyAdoptedLocalReadingsAndFollowsValidityChanges() throws {
        var validity = ClaudeSourceValidity.defaults
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, statusLineEnabled: true,
            withTestStatusLine: true, withInbox: true, sourceValidity: { validity })
        lastStatusLineSessions?.starts["s1"] = Self.start.addingTimeInterval(1)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        deliverStatusLine(session: "s1", five: 24, seven: 42, at: Self.start.addingTimeInterval(5))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        try placeModSnapshot(five: 25, seven: 43, observedAt: Self.start.addingTimeInterval(10))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 25 })
        // An older Mod snapshot that would move both windows backwards is rejected and never drawn.
        try placeModSnapshot(five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(8), as: "balancebar-mod-old.json")
        XCTAssertTrue(pollUntil {
            self.diagnosticLines.all.contains { $0.contains("reason=usage_decreased_within_cycle") }
        })
        pipeline.waitUntilIdle()

        let readings = pipeline.sourceTimeline.snapshot().readings
        XCTAssertEqual(readings.map(\.source), [.oauthAPI, .statusLine, .mod], "one entry per adopted 5h/7d pair")
        XCTAssertEqual(readings.map(\.observedAt), [0, 5, 10].map { Self.start.addingTimeInterval($0) })

        // A longer Mod validity stretches the reading that is still valid now.
        validity.mod = 300
        pipeline.sourceValidityChanged()
        XCTAssertEqual(pipeline.sourceTimeline.snapshot().readings.last?.expiresAt, Self.start.addingTimeInterval(310))
    }

    func testSourceTimelineSurvivesARelaunchForTheSameAccount() throws {
        let first = makePipeline()
        first.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(first) { !$0.windows.isEmpty })
        first.sourceTimeline.flushPendingSave()

        clock.advance(by: 120)
        let relaunched = makePipeline()
        relaunched.start()
        _ = try XCTUnwrap(waitForState(relaunched) { !$0.windows.isEmpty })
        XCTAssertEqual(relaunched.sourceTimeline.snapshot().readings.map(\.observedAt), [Self.start])
    }

    func testSourceTimelineIsClearedOnAccountSwitch() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        let first = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        XCTAssertFalse(pipeline.sourceTimeline.snapshot().readings.isEmpty)
        clock.advance(by: 180)
        PipelineStubProtocol.set(.init(data: Self.nextCycle))
        try writeAccount("account-b", email: "b@example.com")
        _ = try XCTUnwrap(waitForState(pipeline) { $0.accountEpoch != first.accountEpoch && !$0.windows.isEmpty })
        XCTAssertEqual(
            pipeline.sourceTimeline.snapshot().readings.map(\.observedAt), [Self.start.addingTimeInterval(180)],
            "only the new account's read remains")
    }

    /// Sends one statusLine payload over the test socket and waits for the source to read it.
    private func deliverStatusLine(
        session: String = "s1", five: Double, seven: Double, at date: Date,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        clock.advance(by: date.timeIntervalSince(clock.now))
        let object: [String: Any] = [
            "schemaVersion": 1, "sessionID": session,
            "fiveHour": ["usedPercentage": five, "resetsAt": Self.usageFiveReset.timeIntervalSince1970],
            "sevenDay": ["usedPercentage": seven, "resetsAt": Self.usageSevenReset.timeIntervalSince1970],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        guard let socketURL = lastStatusLineSocketURL else {
            XCTFail("no test statusLine socket", file: file, line: line)
            return
        }
        // The listener comes up asynchronously after start; retry the whole delivery briefly.
        var delivered = false
        for _ in 0..<20 {
            if sendStatusLinePayload(socketURL, data) { delivered = true; break }
            usleep(20_000)
        }
        XCTAssertTrue(delivered, "statusLine listener never accepted a connection", file: file, line: line)
        Thread.sleep(forTimeInterval: 0.1)
    }

    private func sendStatusLinePayload(_ socketURL: URL, _ data: Data) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        return true
    }
}

private extension StatusSlotState {
    /// Live from statusLine or the Mod (a fresh official read is also `.realtime(.oauthAPI)`).
    var isNativeRealtime: Bool {
        liveSource == .statusLine || liveSource == .mod
    }

    var liveSource: StatusSlotLiveSource? {
        if case let .realtime(source, _) = self { return source }
        return nil
    }
}
