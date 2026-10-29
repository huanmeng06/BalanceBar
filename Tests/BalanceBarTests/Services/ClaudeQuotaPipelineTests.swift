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

final class ClaudeQuotaPipelineTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private var clock: PipelineClock!
    private var reader: MutableCredentialReader!
    private var official: OfficialQuotaClient!
    private var pipelines: [ClaudeQuotaPipeline] = []
    private var lastIdentity: ClaudeAccountIdentityProvider!
    private var lastInbox: SnapshotInbox?
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
        super.tearDown()
    }

    private var configurationURL: URL { directory.appendingPathComponent("claude.json") }

    private func writeAccount(_ uuid: String, email: String, organization: String = "org") throws {
        let object = ["oauthAccount": ["accountUuid": uuid, "emailAddress": email, "organizationUuid": organization]]
        try JSONSerialization.data(withJSONObject: object).write(to: configurationURL, options: .atomic)
    }

    private func makePipeline(
        reader configurationReader: AccountConfigurationReading = DefaultAccountConfigurationReader(),
        realtimeTracker: ClaudeRealtimeTracker? = nil,
        configuration: FetchSchedulerConfiguration? = nil,
        confirmationTimer: SchedulerTimer = DispatchSchedulerTimer(),
        withTracker: Bool = false,
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
        let tracker = withTracker
            ? (realtimeTracker ?? ClaudeRealtimeTracker(now: { [clock] in clock!.now }))
            : realtimeTracker
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
            snapshotInbox: inbox,
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
        omitSevenDay: Bool = false,
        email: String = "a@example.com",
        emailHash: String? = nil,
        organization: String? = "org",
        as name: String = "balancebar-mod-test.json"
    ) throws {
        var fiveHour: [String: Any] = ["used_percentage": five]
        var sevenHour: [String: Any] = ["used_percentage": seven]
        if !omitResets {
            fiveHour["resets_at"] = Self.isoFormatter.string(from: fiveReset ?? Self.usageFiveReset)
            sevenHour["resets_at"] = Self.isoFormatter.string(from: sevenReset ?? Self.usageSevenReset)
        }
        var object: [String: Any] = [
            "updated_at": Self.isoFormatter.string(from: observedAt),
            "five_hour": fiveHour,
            "source": "balancebar-mod",
            "account": ["email_hash": emailHash ?? SnapshotInbox.emailHash(email)],
        ]
        if !omitSevenDay { object["seven_day"] = sevenHour }
        if let organization {
            object["account"] = [
                "email_hash": emailHash ?? SnapshotInbox.emailHash(email),
                "organization_hash": SnapshotInbox.hash(organization),
            ]
        }
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
            validity: { ClaudeSourceValidity(oauth: 600, mod: 600) },
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
            configuration: claudeV1TestConfiguration, withTracker: true, withInbox: true)
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

        // A byte-identical snapshot rewrite (same production time) is a whole-snapshot replay:
        // the inbox does not even emit it, so it can neither refresh the display nor extend
        // freshness. (A same-value snapshot with a later production time is evidence; see
        // the #634 tests.) Had it been emitted as evidence, the tracker would stay fresh
        // until start+486 and both the notice and the scheduled read below would disagree.
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
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
            configuration: claudeV1TestConfiguration, withTracker: true, withInbox: true)
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

    func testModBelowDisplayWithinToleranceLabelsTheSlotAsModWithoutChangingValues() throws {
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, withTracker: true, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        let official = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        XCTAssertEqual(official.status.liveSource, .oauthAPI)

        // Both Mod values sit one point below the official ones: evidence only, never displayed.
        clock.advance(by: 5)
        try placeModSnapshot(five: 22, seven: 40, observedAt: Self.start.addingTimeInterval(5))
        let live = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(live.display.window(for: .fiveHour)?.usedPercentage, 23)
        XCTAssertEqual(live.display.window(for: .sevenDay)?.usedPercentage, 41)

        // Once the Mod stops renewing, the label follows the displayed (official) reading again.
        clock.advance(by: 130)
        pipeline.tick()
        pipeline.waitUntilIdle()
        let stale = try XCTUnwrap(pipeline.latestState)
        XCTAssertNotEqual(stale.status.liveSource, .mod)
        XCTAssertEqual(stale.display.window(for: .fiveHour)?.usedPercentage, 23)
        XCTAssertEqual(stale.display.window(for: .sevenDay)?.usedPercentage, 41)
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
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(5))
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

    func testFreshModSnapshotOverridesUnauthorizedErrorStatus() throws {
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, withTracker: true, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        PipelineStubProtocol.set(.init(status: 401))
        clock.advance(by: 600)
        pipeline.requestFetch(reason: .manual)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.failure == .unauthorized })

        try placeModSnapshot(five: 24, seven: 41, observedAt: clock.now)
        let state = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(state.failure, .unauthorized, "the official read is still paused; only the card status recovers")

        // Past the real-time freshness (the default 2 minutes) the reading is no longer valid
        // evidence, so the failure matters again and the slot shows how old the data is.
        clock.advance(by: ClaudeSourceValidity.defaults.mod + 5)
        pipeline.tick()
        pipeline.waitUntilIdle()
        guard case .error(_, .mod?) = pipeline.latestState?.status else {
            return XCTFail("expected error once local data went stale, got \(String(describing: pipeline.latestState?.status))")
        }
    }

    func testLongerLocalValidityKeepsFailedReadsFromTurningTheCardRed() throws {
        var validity = ClaudeSourceValidity.defaults
        validity.mod = 600
        let tracker = ClaudeRealtimeTracker(validity: { validity }, now: { [clock] in clock!.now })
        let pipeline = makePipeline(
            realtimeTracker: tracker, configuration: claudeV1TestConfiguration,
            withInbox: true, sourceValidity: { validity })
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        PipelineStubProtocol.set(.init(status: 401))
        clock.advance(by: 600)
        pipeline.requestFetch(reason: .manual)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.failure == .unauthorized })
        try placeModSnapshot(five: 24, seven: 41, observedAt: clock.now)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        clock.advance(by: 400) // well past the default 2 minutes, inside the chosen 10
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertTrue(pipeline.latestState?.status.isNativeRealtime ?? false, "the chosen validity keeps the slot live")
    }

    func testSourceValidityChoiceDrivesTheStatusImmediately() throws {
        var validity = ClaudeSourceValidity.defaults
        validity.mod = 300
        let tracker = ClaudeRealtimeTracker(validity: { validity }, now: { [clock] in clock!.now })
        let pipeline = makePipeline(
            realtimeTracker: tracker, configuration: claudeV1TestConfiguration,
            withInbox: true, sourceValidity: { validity })
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        let at = Self.start.addingTimeInterval(5)
        clock.advance(by: 5)
        try placeModSnapshot(five: 24, seven: 41, observedAt: at)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        clock.advance(by: 200) // 200 s old: stale by default, live under the chosen 5 minutes
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.latestState?.status, .realtime(.mod, at: at))

        validity.mod = 60
        pipeline.sourceValidityChanged()
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.latestState?.status, .official(at: at, source: .mod),
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

    func testModUnavailableKeepsLastReadingButStopsLiveStatusAndLetsOfficialReadResume() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        let producedAt = Self.start.addingTimeInterval(310)
        try placeModSnapshot(five: 25, seven: 42, observedAt: producedAt)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        // Uninstalled while the reading is still inside its validity: live eligibility ends at
        // once, the value and its production time stay, and the scheduler no longer defers.
        pipeline.modBecameUnavailable(reason: .uninstalled)
        let stale = try XCTUnwrap(waitForState(pipeline) { !$0.status.isNativeRealtime })
        XCTAssertEqual(stale.status, .official(at: producedAt, source: .mod))
        XCTAssertEqual(stale.display.window(for: .fiveHour)?.usedPercentage, 25)
        XCTAssertNil(pipeline.manualRefreshNotice())
        XCTAssertNil(stale.failure, "an uninstall is not an OAuth failure")
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("claude mod suspended; reason=uninstalled") })
        pipeline.requestFetch(reason: .scheduled)
        waitForRequests(2)
    }

    func testReinstalledModNeedsASnapshotProducedAfterTheUninstallToBeLiveAgain() throws {
        final class EventBox {
            private let lock = NSLock()
            private var values: [ClaudeQuotaPipeline.ModSnapshotEvent] = []
            func append(_ value: ClaudeQuotaPipeline.ModSnapshotEvent) { lock.lock(); values.append(value); lock.unlock() }
            func snapshot() -> [ClaudeQuotaPipeline.ModSnapshotEvent] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let events = EventBox()
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.modSnapshotEventSink = { events.append($0) }
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })

        clock.advance(by: 15) // start+320
        pipeline.modBecameUnavailable(reason: .uninstalled)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.status.isNativeRealtime })

        // A snapshot produced before the uninstall (old evidence) is displayed but is not live.
        let old = Self.start.addingTimeInterval(315)
        try placeModSnapshot(five: 26, seven: 43, observedAt: old)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 26 })
        XCTAssertEqual(pipeline.latestState?.status, .official(at: old, source: .mod))
        XCTAssertNil(pipeline.manualRefreshNotice())

        // A newer snapshot while the Mod is still uninstalled/disabled stays non-live too.
        let whileUnavailable = Self.start.addingTimeInterval(322)
        try placeModSnapshot(five: 27, seven: 44, observedAt: whileUnavailable)
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 27 })
        XCTAssertEqual(pipeline.latestState?.status, .official(at: whileUnavailable, source: .mod))
        XCTAssertNil(pipeline.manualRefreshNotice())
        let lines = diagnosticLines.all
        XCTAssertTrue(lines.contains { $0.contains("claude mod snapshot not live evidence; reason=snapshot_before_suspension") })
        XCTAssertTrue(lines.contains { $0.contains("claude mod snapshot not live evidence; reason=snapshot_while_mod_unavailable") })
        // Neither late snapshot is reported to the settings entry as trusted evidence.
        let reported = events.snapshot().filter { $0.kind != .processed(accepted: false) }
        XCTAssertEqual(reported.count, 2, "only the pre-uninstall snapshot's two windows were accepted")

        // Once detection confirms the Mod is back, the first snapshot produced afterwards
        // restores `实时 · Mod`.
        clock.advance(by: 3) // start+323: re-enabled after that snapshot was produced
        pipeline.modBecameAvailable()
        pipeline.waitUntilIdle()
        // Rescanning the snapshot written while the Mod was off must not resume live status.
        try placeModSnapshot(five: 27, seven: 44, observedAt: whileUnavailable)
        quiet(pipeline)
        XCTAssertFalse(try XCTUnwrap(pipeline.latestState).status.isNativeRealtime)
        XCTAssertNil(pipeline.manualRefreshNotice())
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("claude mod available confirmed; suspended=true") })
        XCTAssertTrue(diagnosticLines.all.contains {
            $0.contains("claude mod snapshot not live evidence; reason=snapshot_before_available_confirmation")
        })
        clock.advance(by: 7) // start+330
        let fresh = Self.start.addingTimeInterval(325)
        try placeModSnapshot(five: 28, seven: 45, observedAt: fresh)
        let live = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertEqual(live.status, .realtime(.mod, at: fresh))
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("claude mod live resumed; window=") })
        pipeline.requestFetch(reason: .scheduled)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "live Mod evidence defers the official read again")
    }

    // MARK: Issue #634 (Gate F1–F3)

    private final class RequestCounter {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func refreshedEvidenceLines() -> Int {
        diagnosticLines.all.filter { $0.contains("claude native observation refreshed evidence") }.count
    }

    /// F1: an unchanged integer percentage must still keep the Mod live. The newer snapshot is not
    /// merged again, but it renews the local evidence; a re-read of the same file adds nothing.
    func testSameValueNewerModSnapshotRenewsLiveEvidenceButAFileRereadDoesNot() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        // Let directory catch-up rescans settle so the adopted baseline is in place.
        Thread.sleep(forTimeInterval: 0.5)
        quiet(pipeline)
        XCTAssertEqual(refreshedEvidenceLines(), 0)

        clock.advance(by: 100) // start+405: the first snapshot is 95 s old
        let producedAt = Self.start.addingTimeInterval(400)
        try placeModSnapshot(five: 25, seven: 42, observedAt: producedAt)
        XCTAssertTrue(pollUntil { refreshedEvidenceLines() == 2 }, "one line per standard window")
        quiet(pipeline)
        XCTAssertEqual(tracker.lastTrustedRealtimeObservationAt, producedAt)
        XCTAssertEqual(try XCTUnwrap(pipeline.latestState).display.window(for: .fiveHour)?.usedPercentage, 25)

        // The identical file again (same production time) is a replay: no further evidence.
        try placeModSnapshot(five: 25, seven: 42, observedAt: producedAt)
        quiet(pipeline)
        XCTAssertEqual(refreshedEvidenceLines(), 2)

        // 155 s after the first snapshot only the renewed evidence keeps the slot live.
        clock.advance(by: 60)
        pipeline.tick()
        pipeline.waitUntilIdle()
        XCTAssertTrue(try XCTUnwrap(pipeline.latestState).status.isNativeRealtime)
        pipeline.requestFetch(reason: .scheduled)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "renewed Mod evidence still defers the official read")
    }

    /// F2: after an uninstall/reinstall the first snapshot produced after the confirmation resumes
    /// live status even though its values equal the pre-uninstall snapshot.
    func testReinstalledModResumesWithASameValueSnapshot() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        Thread.sleep(forTimeInterval: 0.5)
        quiet(pipeline)

        clock.advance(by: 15) // start+320
        pipeline.modBecameUnavailable(reason: .uninstalled)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.status.isNativeRealtime })
        clock.advance(by: 3)
        pipeline.modBecameAvailable()
        pipeline.waitUntilIdle()
        clock.advance(by: 7) // start+330
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(326))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("claude mod live resumed; window=") })
    }

    /// F3: a snapshot produced after the suspension asks for one availability check; once the check
    /// confirms the Mod, that same snapshot resumes live status (no card visibility, no next snapshot).
    func testSnapshotAfterSuspensionTriggersDetectionAndResumesOnceConfirmed() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        let requests = RequestCounter()
        pipeline.modDetectionRequester = { requests.increment() }
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        Thread.sleep(forTimeInterval: 0.5)
        quiet(pipeline)

        clock.advance(by: 15) // start+320
        pipeline.modBecameUnavailable(reason: .disabled)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.status.isNativeRealtime })
        clock.advance(by: 10) // start+330
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(325))
        XCTAssertTrue(pollUntil { requests.count == 1 }, "the snapshot asks for one detection")
        quiet(pipeline)
        XCTAssertFalse(try XCTUnwrap(pipeline.latestState).status.isNativeRealtime, "not live before the check confirms")

        pipeline.modBecameAvailable()
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        let lines = diagnosticLines.all
        XCTAssertTrue(lines.contains { $0.contains("claude mod live resumed; window=five_hour; trigger=snapshot_detection") })
        XCTAssertTrue(lines.contains { $0.contains("detection_requested=true") })
        XCTAssertEqual(requests.count, 1)
    }

    /// F3 safety: neither a snapshot produced before the suspension nor one whose detection found
    /// the Mod still unavailable may be revived by a later confirmation.
    func testOldOrUnconfirmedSnapshotsNeverResumeLiveStatus() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        let requests = RequestCounter()
        pipeline.modDetectionRequester = { requests.increment() }
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        Thread.sleep(forTimeInterval: 0.5)
        quiet(pipeline)

        clock.advance(by: 15) // start+320
        pipeline.modBecameUnavailable(reason: .uninstalled)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.status.isNativeRealtime })
        // Produced before the suspension: no detection, no candidate.
        try placeModSnapshot(five: 26, seven: 43, observedAt: Self.start.addingTimeInterval(315))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 26 })
        quiet(pipeline)
        XCTAssertEqual(requests.count, 0)
        pipeline.modBecameAvailable()
        quiet(pipeline)
        XCTAssertFalse(try XCTUnwrap(pipeline.latestState).status.isNativeRealtime)

        // Produced after the suspension, but the check it triggered found the Mod still off.
        pipeline.modBecameUnavailable(reason: .uninstalled)
        pipeline.waitUntilIdle()
        clock.advance(by: 10)
        try placeModSnapshot(five: 27, seven: 44, observedAt: Self.start.addingTimeInterval(328))
        XCTAssertTrue(pollUntil { requests.count == 1 })
        pipeline.modBecameUnavailable(reason: .uninstalled)
        pipeline.waitUntilIdle()
        pipeline.modBecameAvailable()
        quiet(pipeline)
        XCTAssertFalse(try XCTUnwrap(pipeline.latestState).status.isNativeRealtime,
                       "a snapshot from before an unavailable verdict never resumes")
    }

    /// B1: no detection request is ever swallowed by a rate limit. After a check found the Mod
    /// still unavailable, a single new snapshot a few seconds later must be able to trigger the
    /// next check and then resume live status.
    func testSingleSnapshotAfterAnUnavailableVerdictStillTriggersDetectionAndResumes() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        let requests = RequestCounter()
        pipeline.modDetectionRequester = { requests.increment() }
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        Thread.sleep(forTimeInterval: 0.5)
        quiet(pipeline)

        clock.advance(by: 15) // start+320
        pipeline.modBecameUnavailable(reason: .disabled)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.status.isNativeRealtime })
        clock.advance(by: 5) // start+325: a snapshot from a stray session
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(324))
        XCTAssertTrue(pollUntil { requests.count == 1 })
        quiet(pipeline)
        clock.advance(by: 2)
        pipeline.modBecameUnavailable(reason: .disabled, checkedAt: clock.now) // the check: still off
        pipeline.waitUntilIdle()

        clock.advance(by: 8) // re-enabled; the only new snapshot, well inside 30 s of the last check
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(334))
        XCTAssertTrue(pollUntil { requests.count == 2 }, "the next snapshot asks for its own check")
        quiet(pipeline)
        pipeline.modBecameAvailable()
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("trigger=snapshot_detection") })
    }

    /// A check that was already running when the snapshot arrived does not cover it: an
    /// "unavailable" verdict from that older check leaves the candidate waiting for the follow-up.
    func testUnavailableVerdictOfACheckThatPredatesTheSnapshotKeepsTheCandidate() throws {
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        let requests = RequestCounter()
        pipeline.modDetectionRequester = { requests.increment() }
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        Thread.sleep(forTimeInterval: 0.5)
        quiet(pipeline)

        clock.advance(by: 15) // start+320
        pipeline.modBecameUnavailable(reason: .disabled)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.status.isNativeRealtime })
        let checkStartedAt = clock.now
        clock.advance(by: 5)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(324))
        XCTAssertTrue(pollUntil { requests.count == 1 })
        quiet(pipeline)
        pipeline.modBecameUnavailable(reason: .disabled, checkedAt: checkStartedAt) // older check
        pipeline.waitUntilIdle()
        pipeline.modBecameAvailable() // the queued follow-up check
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
    }

    /// B1 end to end with the real wiring (`ModSyncCoordinator.bind`) and a fake `claude`:
    /// disable, a stray snapshot, re-enable inside the 30 s window, one new snapshot, no
    /// settings card visible anywhere.
    func testDisableReenableWithinTheThrottleWindowResumesThroughTheRealCoordinatorChain() throws {
        final class PluginState: ModCommandRunning {
            private let lock = NSLock()
            private var enabled = true
            private var lists = 0
            func setEnabled(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
            var listCalls: Int { lock.lock(); defer { lock.unlock() }; return lists }
            func run(executablePath: String, arguments: [String]) -> ModCommandResult? {
                if arguments == ModInstallPlan.versionArguments {
                    return ModCommandResult(exitCode: 0, stdout: "2.1.291 (Claude Code)", stderr: "")
                }
                lock.lock(); defer { lock.unlock() }
                lists += 1
                let list: [[String: Any]] = [[
                    "id": "balancebar-mod@balancebar-mods", "scope": "user", "enabled": enabled,
                    "version": "1.0.0", "installedAt": "2026-10-20T08:00:00.000Z"]]
                let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data()
                return ModCommandResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
        }
        struct Locator: ClaudeExecutableLocating { func locate() -> String? { "/bin/claude" } }
        final class Preference: ModPromptPreferenceStoring { var isPromptDismissed = false }
        let plugin = PluginState()
        let workQueue = DispatchQueue(label: "test.b1.detector")
        let coordinator = ModSyncCoordinator(
            controller: ModOnboardingController(
                installer: ModInstaller(
                    locator: Locator(), runner: plugin, prepareInbox: { true },
                    workQueue: workQueue, callbackQueue: .main),
                preference: Preference()),
            detector: ModSyncDetector(
                locator: Locator(), runner: plugin, inboxDirectory: inboxDirectoryURL,
                workQueue: workQueue, callbackQueue: .main),
            activityProvider: { false })
        let tracker = ClaudeRealtimeTracker(now: { [clock] in clock!.now })
        let pipeline = makePipeline(realtimeTracker: tracker, configuration: claudeV1TestConfiguration, withInbox: true)
        coordinator.bind(to: pipeline)
        func pump(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }
        func pipelineState(_ predicate: (ClaudeQuotaState) -> Bool) -> Bool {
            pump { pipeline.waitUntilIdle(); return pipeline.latestState.map(predicate) ?? false }
        }
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        XCTAssertTrue(pipelineState { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(310))
        XCTAssertTrue(pipelineState { $0.status.isNativeRealtime })
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // The Mod is disabled; a periodic check (any caller) finds out.
        plugin.setEnabled(false)
        clock.advance(by: 15) // start+320
        coordinator.startDetectionIfNeeded(force: true)
        XCTAssertTrue(pipelineState { !$0.status.isNativeRealtime })

        // A stray session still writes a snapshot: it triggers one check, which says "still off".
        clock.advance(by: 5)
        let callsBefore = plugin.listCalls
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(324))
        XCTAssertTrue(pump { plugin.listCalls > callsBefore }, "the snapshot triggers a check")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        pipeline.waitUntilIdle()
        XCTAssertFalse(try XCTUnwrap(pipeline.latestState).status.isNativeRealtime)

        // Re-enabled seconds later; the only new snapshot triggers the next check at once.
        plugin.setEnabled(true)
        clock.advance(by: 8)
        let callsAfterStray = plugin.listCalls
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(334))
        XCTAssertTrue(pump { plugin.listCalls > callsAfterStray }, "a second check inside the 30 s window")
        XCTAssertTrue(pipelineState { $0.status.isNativeRealtime }, "live again without a further snapshot")
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

        // One window changed, the other repeated its value: the whole snapshot is fresh evidence, so both windows are re-recorded.
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

    func testIncompleteModSnapshotCannotEstablishTheNextCycleWhileResetIsPending() throws {
        PipelineStubProtocol.set(.init(data: Self.nearReset))
        let pipeline = makePipeline(
            configuration: claudeV1TestConfiguration, confirmationTimer: ManualRetryTimer(), withInbox: true)
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 120)
        pipeline.tick()
        waitForRequests(2)

        try placeModSnapshot(
            five: 2, seven: 42, observedAt: Self.start.addingTimeInterval(125),
            fiveReset: Self.start.addingTimeInterval(10_000), sevenReset: Self.nearResetSevenReset,
            omitSevenDay: true)
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertTrue(pollUntil {
            inbox.adapters.contains { adapter in
                if case let .degraded(reason) = adapter.health, reason.contains("cycle_unverified") { return true }
                return false
            }
        }, "a snapshot without both windows cannot confirm the next cycle")
        quiet(pipeline)
        XCTAssertNotNil(pipeline.mergeStateForDiagnostics?.windows[QuotaWindowKind.fiveHour.rawValue]?.pendingResetOf)
        XCTAssertNotEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 2)
    }

    func testModSnapshotProducedBeforeTheAccountWasActiveIsRejectedWithoutOfficialBaseline() throws {
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        // No official read: the email hash cannot tell two organizations of one email apart, so a
        // snapshot produced before this account became active here is not attributed to it.
        try placeModSnapshot(five: 90, seven: 95, observedAt: Self.start.addingTimeInterval(-3_600))
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertTrue(pollUntil {
            inbox.adapters.contains { adapter in
                if case let .degraded(reason) = adapter.health, reason.contains("cycle_unverified") { return true }
                return false
            }
        })
        quiet(pipeline)
        XCTAssertNotEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 90)

        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(10))
        let live = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 25 })
        XCTAssertTrue(live.status.isNativeRealtime)
    }

    func testSameEmailOtherOrganizationSnapshotIsRejectedAndNewOrganizationSnapshotIsAcceptedWithoutBaseline() throws {
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        try placeModSnapshot(five: 20, seven: 40, observedAt: Self.start.addingTimeInterval(10),
                             as: "balancebar-mod-aaaa-org1.json")
        let first = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 20 })

        // Switch to another organization of the same account and email; no official read happened.
        clock.advance(by: 60)
        try writeAccount("account-a", email: "a@example.com", organization: "org-2")
        _ = try XCTUnwrap(waitForState(pipeline) { $0.accountEpoch != first.accountEpoch })

        // A session still running under the old organization writes a fresh snapshot: rejected.
        clock.advance(by: 30)
        try placeModSnapshot(five: 77, seven: 88, observedAt: clock.now, as: "balancebar-mod-aaaa-org1.json")
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertTrue(pollUntil {
            inbox.adapters.contains { adapter in
                if case let .degraded(reason) = adapter.health, reason.contains("organization hash") { return true }
                return false
            }
        })
        quiet(pipeline)
        XCTAssertNotEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 77)

        // The new organization writes its own file: accepted.
        clock.advance(by: 10)
        try placeModSnapshot(five: 30, seven: 50, observedAt: clock.now, organization: "org-2",
                             as: "balancebar-mod-aaaa-org2.json")
        let live = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 30 })
        XCTAssertTrue(live.status.isNativeRealtime)
    }

    func testLegacyModSnapshotWithoutOrganizationIsRejectedWithoutBaselineButAcceptedWithOne() throws {
        let pipeline = makePipeline(configuration: claudeV1TestConfiguration, withInbox: true)
        pipeline.start()
        try placeModSnapshot(five: 25, seven: 42, observedAt: Self.start.addingTimeInterval(10), organization: nil)
        let inbox = try XCTUnwrap(lastInbox)
        XCTAssertTrue(pollUntil {
            inbox.adapters.contains { adapter in
                if case let .degraded(reason) = adapter.health, reason.contains("cycle_unverified") { return true }
                return false
            }
        })
        quiet(pipeline)
        XCTAssertNotEqual(pipeline.latestState?.display.window(for: .fiveHour)?.usedPercentage, 25)

        // With an official baseline the cycle check governs and the legacy snapshot is unchanged behavior.
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 305)
        try placeModSnapshot(five: 26, seven: 43, observedAt: Self.start.addingTimeInterval(310), organization: nil)
        let live = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 26 })
        XCTAssertTrue(live.status.isNativeRealtime)
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
            configuration: claudeV1TestConfiguration, withTracker: true, withInbox: true,
            sourceValidity: { validity })
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })

        clock.advance(by: 5)
        try placeModSnapshot(five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(5))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status.isNativeRealtime })
        clock.advance(by: 5)
        try placeModSnapshot(five: 25, seven: 43, observedAt: Self.start.addingTimeInterval(10))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.display.window(for: .fiveHour)?.usedPercentage == 25 })
        // An older Mod snapshot that would move both windows backwards is rejected and never drawn.
        try placeModSnapshot(five: 24, seven: 42, observedAt: Self.start.addingTimeInterval(8), as: "balancebar-mod-old.json")
        XCTAssertTrue(pollUntil {
            self.diagnosticLines.all.contains { $0.contains("reason=usage_decreased_within_cycle") }
        })
        pipeline.waitUntilIdle()

        let readings = pipeline.sourceTimeline.snapshot().readings
        XCTAssertEqual(readings.map(\.source), [.oauthAPI, .mod, .mod], "one entry per adopted 5h/7d pair")
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
}

private extension StatusSlotState {
    /// Live from the Mod (a fresh official read is also `.realtime(.oauthAPI)`).
    var isNativeRealtime: Bool {
        liveSource == .mod
    }

    var liveSource: StatusSlotLiveSource? {
        if case let .realtime(source, _) = self { return source }
        return nil
    }
}
