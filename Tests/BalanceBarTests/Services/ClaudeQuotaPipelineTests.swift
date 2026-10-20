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
    func claudeAccessToken() -> String? { lock.lock(); defer { lock.unlock() }; readCount += 1; return token }
    private var readCount = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
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

private final class LockedLines {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ line: String) { lock.lock(); values.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

/// A real-time source the test drives by hand, in place of the HUD file watcher or the snapshot inbox.
private final class ManualRealtimeSource: QuotaSource {
    let sourceID = "manual-realtime"
    private let lock = NSLock()
    private var handler: ((QuotaObservation) -> Void)?
    private(set) var stopCount = 0
    var isStarted: Bool { lock.withLock { handler != nil } }
    func start(receiving handler: @escaping (QuotaObservation) -> Void) { lock.withLock { self.handler = handler } }
    func stop() { lock.withLock { handler = nil; stopCount += 1 } }
    func emit(_ observation: QuotaObservation) { lock.withLock { handler }?(observation) }
}

private final class ObservationLog {
    private let lock = NSLock()
    private var values: [(source: String, accepted: Bool)] = []
    func append(_ source: String, _ accepted: Bool) { lock.withLock { values.append((source, accepted)) } }
    var all: [(source: String, accepted: Bool)] { lock.withLock { values } }
}

final class ClaudeQuotaPipelineTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private var clock: PipelineClock!
    private var reader: MutableCredentialReader!
    private var official: OfficialQuotaClient!
    private var pipelines: [ClaudeQuotaPipeline] = []
    private let diagnosticLines = LockedLines()

    private static let start = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
    private static let usage = Data(#"{"five_hour":{"utilization":23,"resets_at":"2023-11-15T03:00:00Z"},"seven_day":{"utilization":41,"resets_at":"2023-11-20T00:00:00Z"}}"#.utf8)
    private static let nextCycle = Data(#"{"five_hour":{"utilization":2,"resets_at":"2023-11-15T08:00:00Z"},"seven_day":{"utilization":42,"resets_at":"2023-11-20T00:00:00Z"}}"#.utf8)

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

    private func writeAccount(_ uuid: String, email: String) throws {
        let object = ["oauthAccount": ["accountUuid": uuid, "emailAddress": email, "organizationUuid": "org"]]
        try JSONSerialization.data(withJSONObject: object).write(to: configurationURL, options: .atomic)
    }

    private func makePipeline(
        reader configurationReader: AccountConfigurationReading = DefaultAccountConfigurationReader(),
        realtimeSources: [QuotaSource] = [],
        calibrationIntervalCap: @escaping () -> TimeInterval? = { nil }
    ) -> ClaudeQuotaPipeline {
        let identityQueue = DispatchQueue(label: "test.pipeline.identity")
        let identity = ClaudeAccountIdentityProvider(
            configurationURL: configurationURL, reader: configurationReader,
            workQueue: identityQueue, coalescingInterval: 0.02, now: { [clock] in clock!.now })
        var configuration = FetchSchedulerConfiguration()
        configuration.coalescingWindow = 0.02
        let pipeline = ClaudeQuotaPipeline(
            client: official, identity: identity, identityQueue: identityQueue,
            stateDirectory: directory.appendingPathComponent("state", isDirectory: true),
            realtimeSources: realtimeSources, calibrationIntervalCap: calibrationIntervalCap,
            schedulerClock: clock, schedulerConfiguration: configuration, now: { [clock] in clock!.now },
            diagnostics: { [diagnosticLines] message, _ in diagnosticLines.append(message) })
        pipelines.append(pipeline)
        return pipeline
    }

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
        let began = Date()
        pipeline.start()
        pipeline.requestFetch(reason: .initial)
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "start and request must not wait for file IO")
        XCTAssertNil(pipeline.latestState)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        gate.release.signal()
        gate.release.signal()
        let state = waitForState(pipeline) { !$0.windows.isEmpty }
        XCTAssertEqual(state?.windows.map(\.remaining), [77, 59])
    }

    func testFirstLaunchReadsOnceAndPublishesOfficialStatus() throws {
        let pipeline = makePipeline()
        pipeline.requestFetch(reason: .initial)
        let state = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        XCTAssertEqual(state.status, .official(at: Self.start))
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
        XCTAssertEqual(restarted.manualRefreshNotice(), .justRefreshed, "the login-expired hint is gone once a read succeeds")
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
        XCTAssertEqual(pipeline.manualRefreshNotice(), .justRefreshed)

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
        XCTAssertEqual(failed.status, .error(at: Self.start))

        PipelineStubProtocol.set(.init(data: Self.usage))
        clock.advance(by: 360)
        pipeline.requestFetch(reason: .scheduled)
        let recovered = try XCTUnwrap(waitForState(pipeline) { $0.failure == nil && $0.updatedAt == Self.start.addingTimeInterval(540) })
        XCTAssertEqual(recovered.status, .official(at: Self.start.addingTimeInterval(540)))
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
        XCTAssertEqual(confirmed.status, .official(at: clock.now))
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
        XCTAssertEqual(state.windows.first?.remaining, 77, "an old-cycle reading is not a confirmation")
    }

    // MARK: Local real-time sources (INT-2)

    private static let resetFiveHour = ISO8601DateFormatter().date(from: "2023-11-15T03:00:00Z")!
    private static let resetSevenDay = ISO8601DateFormatter().date(from: "2023-11-20T00:00:00Z")!

    /// A grade-B reading of the same cycle as `usage`, received at the pipeline clock.
    private func hudObservation(
        _ window: QuotaWindowKind = .fiveHour, used: Double, source: String = "claude-hud",
        account: String = "claude:account-a:org", epoch: AccountEpoch? = nil, pipeline: ClaudeQuotaPipeline
    ) -> QuotaObservation {
        QuotaObservation(
            window: window, usedPercentage: used,
            resetsAt: window == .fiveHour ? Self.resetFiveHour : Self.resetSevenDay,
            receivedAt: clock.now, source: source, trust: .b, accountID: account,
            epoch: epoch ?? pipeline.latestState?.accountEpoch ?? .initial)!
    }

    /// Seeds the official reading and moves the clock past the 3-minute automatic minimum.
    private func seededPipeline(
        source: ManualRealtimeSource, calibrationIntervalCap: @escaping () -> TimeInterval? = { nil }
    ) throws -> ClaudeQuotaPipeline {
        let pipeline = makePipeline(realtimeSources: [source], calibrationIntervalCap: calibrationIntervalCap)
        pipeline.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(pipeline) { !$0.windows.isEmpty })
        clock.advance(by: 200)
        return pipeline
    }

    func testFreshHUDReadingSuppressesAutomaticRequestsAndShowsTheRealtimeStatus() throws {
        let source = ManualRealtimeSource()
        let pipeline = try seededPipeline(source: source)
        XCTAssertTrue(source.isStarted, "local sources start together with the pipeline")

        source.emit(hudObservation(used: 27, pipeline: pipeline))
        let live = try XCTUnwrap(waitForState(pipeline) { $0.windows.first?.remaining == 73 })
        XCTAssertEqual(live.status, .realtime)

        let credentialReads = reader.reads
        pipeline.requestFetch(reason: .scheduled)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "a fresh live reading answers the scheduled refresh")
        XCTAssertEqual(reader.reads, credentialReads, "…and the credential store is not even consulted")
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("skip=realtimeSourceFresh") })

        // The live reading goes stale after two minutes: ordinary reads resume.
        clock.advance(by: 125)
        pipeline.requestFetch(reason: .scheduled)
        waitForRequests(2)
    }

    func testRejectedLiveReadingDoesNotSuppressRequests() throws {
        let source = ManualRealtimeSource()
        let pipeline = try seededPipeline(source: source)
        // 5 points below the official 23% is outside the grade-B tolerance, so it is not displayed.
        source.emit(hudObservation(used: 18, pipeline: pipeline))
        // Another account's snapshot is not displayed either.
        source.emit(hudObservation(used: 30, account: "claude:someone-else:org", pipeline: pipeline))
        quiet(pipeline)
        XCTAssertEqual(pipeline.latestState?.windows.first?.remaining, 77)

        pipeline.requestFetch(reason: .scheduled)
        waitForRequests(2)
    }

    func testLiveReadingsDoNotSuppressConfirmationOfAPassedResetTime() throws {
        let source = ManualRealtimeSource()
        let pipeline = try seededPipeline(source: source)
        source.emit(hudObservation(used: 27, pipeline: pipeline))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status == .realtime })

        // The 5-hour reset time passes while the seven-day window keeps receiving live readings.
        clock.advance(by: 5 * 3_600)
        PipelineStubProtocol.set(.init(data: Self.nextCycle))
        source.emit(hudObservation(.sevenDay, used: 45, pipeline: pipeline))
        pipeline.tick()
        waitForRequests(2)
        let confirmed = try XCTUnwrap(waitForState(pipeline) { $0.windows.first?.remaining == 98 })
        XCTAssertEqual(confirmed.windows.last?.remaining, 58, "the official read also refreshed the seven-day window")
    }

    func testCalibrationCapAllowsOneReadWhileLiveReadingsKeepArriving() throws {
        let source = ManualRealtimeSource()
        let pipeline = try seededPipeline(source: source, calibrationIntervalCap: { 600 })
        for step in 0..<3 {
            source.emit(hudObservation(used: Double(27 + step), pipeline: pipeline))
            _ = try XCTUnwrap(waitForState(pipeline) { $0.windows.first?.remaining == Double(73 - step) })
            pipeline.requestFetch(reason: .scheduled)
            quiet(pipeline)
            clock.advance(by: 100)
        }
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1, "no request while the cap has not passed")

        // 700 s after the last official read the cap has passed, so one calibration read is allowed.
        clock.advance(by: 200)
        source.emit(hudObservation(used: 31, pipeline: pipeline))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.windows.first?.remaining == 69 })
        pipeline.requestFetch(reason: .scheduled)
        waitForRequests(2)
    }

    func testManualRefreshIsAnsweredByAFreshLiveReadingWithoutARequest() throws {
        let source = ManualRealtimeSource()
        let pipeline = try seededPipeline(source: source)
        XCTAssertNil(pipeline.manualRefreshNotice())
        source.emit(hudObservation(used: 27, pipeline: pipeline))
        _ = try XCTUnwrap(waitForState(pipeline) { $0.status == .realtime })
        XCTAssertEqual(pipeline.manualRefreshNotice(), .justRefreshed)

        pipeline.requestFetch(reason: .manual)
        quiet(pipeline)
        XCTAssertEqual(PipelineStubProtocol.requestCount, 1)
        XCTAssertTrue(diagnosticLines.all.contains { $0.contains("skip=freePathSatisfied") })

        clock.advance(by: 61)
        XCTAssertNil(pipeline.manualRefreshNotice())
        pipeline.requestFetch(reason: .manual)
        waitForRequests(2)
    }

    func testAccountSwitchDropsTheLiveTrustAndOldReadings() throws {
        let source = ManualRealtimeSource()
        let pipeline = try seededPipeline(source: source)
        source.emit(hudObservation(used: 27, pipeline: pipeline))
        let live = try XCTUnwrap(waitForState(pipeline) { $0.status == .realtime })

        try writeAccount("account-b", email: "b@example.com")
        let switched = try XCTUnwrap(waitForState(pipeline) { $0.accountEpoch != live.accountEpoch && !$0.windows.isEmpty })
        XCTAssertNotEqual(switched.status, .realtime, "the previous account's live reading never vouches for the new account")
        XCTAssertEqual(switched.windows.first?.remaining, 77, "the new account shows its own official reading")
    }

    func testRealtimeObserverSeesEveryObservationWithItsAcceptance() throws {
        let source = ManualRealtimeSource()
        let pipeline = try seededPipeline(source: source)
        let log = ObservationLog()
        pipeline.realtimeObserver = { observation, accepted in log.append(observation.source, accepted) }
        source.emit(hudObservation(used: 27, source: "balancebar-mod", pipeline: pipeline))
        source.emit(hudObservation(used: 10, source: "claude-hud", pipeline: pipeline))
        quiet(pipeline)
        XCTAssertEqual(log.all.map(\.source), ["balancebar-mod", "claude-hud"])
        XCTAssertEqual(log.all.map(\.accepted), [true, false])
    }

    func testStoppingThePipelineStopsItsLocalSources() throws {
        let source = ManualRealtimeSource()
        var pipeline: ClaudeQuotaPipeline? = makePipeline(realtimeSources: [source])
        pipeline?.requestFetch(reason: .initial)
        _ = try XCTUnwrap(waitForState(try XCTUnwrap(pipeline)) { !$0.windows.isEmpty })
        pipelines.removeAll()
        pipeline = nil
        XCTAssertEqual(source.stopCount, 1)
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
        XCTAssertEqual(confirmed.status, .official(at: clock.now))
    }
}
