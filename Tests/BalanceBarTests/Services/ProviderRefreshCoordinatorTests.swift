import Foundation
import SQLite3
import XCTest
@testable import BalanceBar

final class ProviderRefreshCoordinatorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!
    private var repository: CCSwitchRepository!
    private var session: URLSession!
    private var sessionLifetime: FixtureSessionLifetime!
    private var coordinators: [ProviderRefreshCoordinator] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-ProviderRefresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        databaseURL = temporaryDirectoryURL.appendingPathComponent("cc-switch.db")
        try createFixtureDatabase()
        repository = CCSwitchRepository(
            databaseURL: databaseURL,
            appSettingsURL: temporaryDirectoryURL.appendingPathComponent("settings.json"),
            homeDirectoryURL: temporaryDirectoryURL
        )
        let codex = temporaryDirectoryURL.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data("model_provider = \"custom\"\n[model_providers.custom]\nbase_url = \"https://codex.provider.test\"\n".utf8).write(to: codex.appendingPathComponent("config.toml"))
        try Data(#"{"OPENAI_API_KEY":"fixture-key"}"#.utf8).write(to: codex.appendingPathComponent("auth.json"))
        try FileManager.default.createDirectory(at: repository.deviceStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"apps":{"codex":{"mode":"direct"}}}"#.utf8).write(to: repository.deviceStateURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedBalanceURLProtocol.self]
        sessionLifetime = FixtureSessionLifetime()
        session = URLSession(configuration: configuration, delegate: sessionLifetime, delegateQueue: nil)
        DelayedBalanceURLProtocol.reset()
    }

    override func tearDown() {
        // Prevent queued refresh work from creating tasks against an invalid
        // session, then wait for cancellation before deleting database fixtures.
        coordinators.forEach { $0.stop() }
        session?.invalidateAndCancel()
        XCTAssertTrue(sessionLifetime.waitUntilInvalidated(), "fixture session did not finish cancellation")
        XCTAssertTrue(DelayedBalanceURLProtocol.waitUntilIdle(), "fixture protocol workers did not finish")
        coordinators.forEach { $0.stop() } // Drain late callbacks, which are now rejected.
        coordinators.removeAll()
        session = nil
        sessionLifetime = nil
        DelayedBalanceURLProtocol.reset()
        repository = nil
        if let temporaryDirectoryURL {
            UserDefaults.standard.removePersistentDomain(forName: temporaryDirectoryURL.lastPathComponent + ".Aggregation")
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        super.tearDown()
    }

    func testStoppedCoordinatorRejectsLateCallbacksAndRefreshesAgainstInvalidatedSession() throws {
        let started = expectation(description: "delayed transport started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DelayedBalanceURLProtocol.setHandler { _ in
            started.fulfill()
            return .init(data: Data(#"{"balance":9,"quota":{"unit":"USD"}}"#.utf8), statusCode: 200, delayUntil: release)
        }
        var publications = 0
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            actions: .init(currentProvider: { [repository] client in repository?.loadCurrent(appType: client.appType) },
                isActiveClient: { _ in true }, render: { _ in publications += 1 },
                storeClientSnapshot: { _, _, _ in publications += 1 },
                quickSwitchSummaryChanged: { _ in publications += 1 },
                notificationSnapshot: { _, _, _ in publications += 1 }))
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: ["codex-custom"])
        wait(for: [started], timeout: 2)
        coordinator.stop()
        session.invalidateAndCancel()
        XCTAssertTrue(sessionLifetime.waitUntilInvalidated())
        // These used to create a task in an invalidated session (fatal NSException).
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex)
        coordinator.prefetchCurrentBalance(for: .claude)
        coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: true, switched: false)
        coordinator.resetCadence()
        coordinator.performAsync { XCTFail("stopped queued work must not run") }
        release.signal()
        XCTAssertTrue(DelayedBalanceURLProtocol.waitUntilIdle())
        coordinator.stop() // Idempotent owner-queue barrier drains rejected callbacks.
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .defaultValue).isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !condition() { Thread.sleep(forTimeInterval: 0.005) }
    }

    /// #533: low API balance stored while reminders are off -> reminders on -> request fails ->
    /// permission re-check must not alert from the stale sample -> real refresh alerts normally.
    private func assertAPIFailureNeverAlertsFromStaleSample(
        refresh: (ProviderRefreshCoordinator, CCSwitchProvider) -> Void
    ) throws {
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        let (notifications, notificationClient, enableNotifications) = notificationHarness(providerID: current.id, agent: .gpt)
        let lock = NSLock()
        var invalidations = 0
        var samples = 0
        var actions = makeActions()
        wire(&actions, to: notifications)
        let forwardSample = actions.notificationSnapshot
        let forwardInvalidation = actions.notificationSamplesInvalidated
        actions.notificationSnapshot = { client, id, snapshot in
            forwardSample?(client, id, snapshot); lock.lock(); samples += 1; lock.unlock()
        }
        actions.notificationSamplesInvalidated = { client, ids in
            forwardInvalidation?(client, ids); lock.lock(); invalidations += 1; lock.unlock()
        }
        func count(_ value: () -> Int) -> Int { lock.lock(); defer { lock.unlock() }; return value() }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session), actions: actions)

        // A low balance sample is stored while reminders are still off.
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "3.00") }
        refresh(coordinator, current)
        waitUntil { count { samples } == 1 }
        XCTAssertEqual(count { samples }, 1)
        enableNotifications()
        XCTAssertTrue(notificationClient.deliveries.isEmpty)

        // The balance endpoint now fails; reactivating the app re-checks permission.
        DelayedBalanceURLProtocol.setHandler { _ in .init(data: Data(), statusCode: 500) }
        refresh(coordinator, current)
        waitUntil { count { invalidations } == 1 }
        XCTAssertEqual(count { invalidations }, 1)
        notifications.refreshPermission()
        waitForCoordinator(coordinator)
        XCTAssertTrue(notificationClient.deliveries.isEmpty, "a failed API request must not re-evaluate the stale balance")

        // The first real refresh alerts normally.
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "3.00") }
        refresh(coordinator, current)
        waitUntil { count { samples } == 2 }
        waitUntil { notificationClient.deliveries.count == 1 }
        XCTAssertEqual(notificationClient.deliveries.count, 1)
    }

    func testStandardAPIBalanceFailureNeverAlertsFromStaleSampleUntilRefreshSucceeds() throws {
        try assertAPIFailureNeverAlertsFromStaleSample { coordinator, current in
            coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: true, switched: false)
        }
    }

    func testQuickSwitchAPIBalanceFailureNeverAlertsFromStaleSampleUntilRefreshSucceeds() throws {
        try assertAPIFailureNeverAlertsFromStaleSample { coordinator, current in
            coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: [current.id])
        }
    }

    func testStopWaitsForOwnerWorkBeforeCallerInvalidatesTransport() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let stopped = expectation(description: "stop finishes after queued owner work")
        let stopStarted = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session), actions: makeActions())
        coordinator.performAsync {
            entered.signal()
            release.wait()
        }
        waitForEvent(entered)
        DispatchQueue.global().async {
            stopStarted.signal()
            coordinator.stop()
            stopReturned.signal()
            stopped.fulfill()
        }
        waitForEvent(stopStarted)
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.05), .timedOut, "stop cannot return while owner work is still running")
        release.signal()
        wait(for: [stopped], timeout: 3)
        session.invalidateAndCancel()
        XCTAssertTrue(sessionLifetime.waitUntilInvalidated())
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex)
        coordinator.stop()
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 0)
    }

    func testDelayedInactiveClientPrefetchIsCachedWithoutReplacingActiveSnapshot() throws {
        let claudeStarted = DispatchSemaphore(value: 0)
        let releaseClaude = DispatchSemaphore(value: 0)
        DelayedBalanceURLProtocol.setHandler { request in
            if request.url?.host == "claude.provider.test" {
                claudeStarted.signal()
                releaseClaude.wait()
                return DelayedBalanceURLProtocol.success(amount: "1.30")
            }
            return DelayedBalanceURLProtocol.success(amount: "28.00", unit: "USD")
        }

        let recorder = PublicationRecorder()
        let activeClient = ActiveClientBox(.codex)
        let claudeStored = expectation(description: "inactive Claude snapshot cached")
        let codexRendered = expectation(description: "active Codex snapshot rendered")
        let actions = ProviderRefreshActions(
            currentProvider: { [repository] client in
                repository?.loadCurrent(appType: client.appType)
            },
            isActiveClient: { [activeClient] client in
                activeClient.value == client
            },
            render: { snapshot in
                recorder.recordRender(snapshot)
                if snapshot.provider == "Codex Custom" {
                    codexRendered.fulfill()
                }
            },
            storeClientSnapshot: { client, providerID, snapshot in
                recorder.store(snapshot, client: client, providerID: providerID)
                if client == .claude {
                    claudeStored.fulfill()
                }
            },
            quickSwitchSummaryChanged: { _ in },
        )
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh"),
            actions: actions
        )

        let codexCurrent = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(
            current: codexCurrent,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        coordinator.prefetchCurrentBalance(for: .claude)

        XCTAssertEqual(claudeStarted.wait(timeout: .now() + 2), .success)
        wait(for: [codexRendered], timeout: 2)
        XCTAssertEqual(recorder.rendered.map(\.provider), ["Codex Custom"])

        releaseClaude.signal()
        wait(for: [claudeStored], timeout: 2)

        XCTAssertEqual(recorder.rendered.map(\.provider), ["Codex Custom"])
        XCTAssertEqual(recorder.stored[.claude]?.providerID, "claude-custom")
        XCTAssertEqual(recorder.stored[.claude]?.snapshot.kind, .balance)

        // The cached Claude result remains available for a later client switch.
        activeClient.value = .claude
        XCTAssertEqual(try XCTUnwrap(recorder.stored[.claude]?.snapshot.amount), 1.30, accuracy: 0.000001)
    }

    func testProviderChangeDuringRequestDropsLateCallback() throws {
        let requestStarted = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        DelayedBalanceURLProtocol.setHandler { _ in
            requestStarted.signal()
            releaseRequest.wait()
            return DelayedBalanceURLProtocol.success(amount: "9.00")
        }

        let recorder = PublicationRecorder()
        let callbackCompleted = expectation(description: "late callback completed")
        let actions = ProviderRefreshActions(
            currentProvider: { [repository] client in repository?.loadCurrent(appType: client.appType) },
            isActiveClient: { _ in true },
            render: { recorder.recordRender($0) },
            storeClientSnapshot: { client, providerID, snapshot in
                recorder.store(snapshot, client: client, providerID: providerID)
            },
            quickSwitchSummaryChanged: { _ in callbackCompleted.fulfill() },
        )
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-stale"),
            actions: actions
        )

        let codexCurrent = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(
            current: codexCurrent,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        XCTAssertEqual(requestStarted.wait(timeout: .now() + 2), .success)
        try setCurrentProvider("codex-replacement")
        releaseRequest.signal()

        wait(for: [callbackCompleted], timeout: 2)
        XCTAssertTrue(recorder.rendered.isEmpty)
        XCTAssertTrue(recorder.stored.isEmpty)
    }

    func testConcurrentStandardRefreshReadsAreConfinedToCoordinatorQueue() throws {
        DelayedBalanceURLProtocol.setHandler { _ in
            DelayedBalanceURLProtocol.success(amount: "12.00")
        }
        let dateSource = ConcurrentDateSource(date: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-confinement"),
            actions: makeActions(),
            now: { dateSource.read() }
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            coordinator.refreshStandardProvider(
                current: current,
                client: .codex,
                forceBalance: false,
                switched: false
            )
        }

        waitForEvent(dateSource.firstRead)
        dateSource.releaseFirstRead()
        waitForCoordinator(coordinator)

        XCTAssertEqual(
            dateSource.maximumConcurrentReads,
            1,
            "cadence reads must never execute concurrently"
        )
    }

    func testStandardProviderCadenceRetainsConfiguredIntervalAndResetBehavior() throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let summaryUpdated = DispatchSemaphore(value: 0)
        let responseCounter = IncrementingCounter()
        DelayedBalanceURLProtocol.setHandler { _ in
            let amount = responseCounter.next()
            return DelayedBalanceURLProtocol.success(amount: "\(amount).00")
        }
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-standard-cadence"),
            actions: makeActions { _ in summaryUpdated.signal() },
            now: { clock.now }
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        let interval = TimeInterval(max(current.query?.intervalMinutes ?? 1, 1) * 60)

        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        clock.advance(by: interval - 1)
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        clock.advance(by: 1)
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)

        coordinator.resetCadence()
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)
    }

    func testOfficialProviderCadenceRetainsSixtySecondIntervalAndResetBehavior() throws {
        try setCurrentProvider("codex-replacement")
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let summaryUpdated = DispatchSemaphore(value: 0)
        let responseCounter = IncrementingCounter()
        DelayedBalanceURLProtocol.setHandler { _ in
            DelayedBalanceURLProtocol.success(amount: "0.00")
        }
        let officialClient = OfficialQuotaClient(
            session: session,
            credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
            parser: IncrementingOfficialQuotaParser(counter: responseCounter)
        )
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: officialClient,
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-official-cadence"),
            actions: makeActions { _ in summaryUpdated.signal() },
            now: { clock.now }
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))

        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        clock.advance(by: 59)
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        clock.advance(by: 1)
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)

        coordinator.resetCadence()
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)
    }

    func testConfiguredOfficialCadenceHonorsSelectedIntervalForCodex() throws {
        try setCurrentProvider("codex-replacement")
        let suite = "OfficialCadence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.officialUsageRefreshInterval = 180
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let ready = DispatchSemaphore(value: 0)
        DelayedBalanceURLProtocol.setHandler { _ in .init(data: Data("{}".utf8), statusCode: 200) }
        let coordinator = makeCoordinator(repository: repository,
            officialQuotaClient: OfficialQuotaClient(session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture"),
                parser: IncrementingOfficialQuotaParser(counter: IncrementingCounter())),
            actions: makeActions { _ in ready.signal() }, refreshPreferences: preferences, now: { clock.now })
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: true, switched: false)
        waitForEvent(ready)
        clock.advance(by: 179)
        coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: true, switched: false)
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        clock.advance(by: 1)
        coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: false, switched: false)
        waitForEvent(ready)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
    }

    // MARK: Codex local rollout log (INT-2)

    func testFreshCodexRolloutLogStandsInForTheUsageRequestUntilItGoesStaleOrTheUserRefreshes() throws {
        try setCurrentProvider("codex-replacement")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(date: base)
        let suite = "CodexLocalLog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)

        // A Codex rollout log whose newest event is 10 s old, for the signed-in login.
        let sessions = temporaryDirectoryURL.appendingPathComponent("rollouts/sessions/2026/10/19", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fiveHourReset = Int(base.timeIntervalSince1970) + 10_000
        let sevenDayReset = Int(base.timeIntervalSince1970) + 400_000
        let event = "{\"timestamp\":\"\(stamp.string(from: base.addingTimeInterval(-10)))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"used_percent\":35,\"window_minutes\":300,\"resets_at\":\(fiveHourReset)},\"secondary\":{\"used_percent\":15,\"window_minutes\":10080,\"resets_at\":\(sevenDayReset)}}}}\n"
        let sessionMeta = "{\"timestamp\":\"\(stamp.string(from: base.addingTimeInterval(-60)))\",\"type\":\"session_meta\",\"payload\":{\"creator_account_id\":\"acct-1\"}}\n"
        try Data((sessionMeta + event).utf8).write(to: sessions.appendingPathComponent("rollout-a.jsonl"))
        let identity = CodexAccountIdentityProvider(
            readProfile: { CodexAccountProfile(email: "me@example.com", planType: "plus", accountID: "acct-1") },
            refreshInterval: 1, now: { clock.now })
        let source = CodexRolloutSource(
            sessionsDirectory: temporaryDirectoryURL.appendingPathComponent("rollouts/sessions"),
            accountProvider: identity, configuration: CodexRolloutConfiguration(maximumFileAge: .infinity), now: { clock.now },
            currentAccountID: { [identity] in identity.accountID })
        let local = CodexLocalQuota(identity: identity, source: source,
            stateDirectory: temporaryDirectoryURL.appendingPathComponent("codex-state"), now: { clock.now })
        defer { local.stop() }

        let fiveHour = OfficialQuotaWindow(kind: .fiveHour, remaining: 80, label: "5-hour quota", daysText: "5 hours",
            reset: "server", durationSeconds: 18_000, resetAt: base.addingTimeInterval(9_000))
        let sevenDay = OfficialQuotaWindow(kind: .sevenDay, remaining: 45, label: "7-day quota", daysText: "7 days",
            reset: "server", durationSeconds: 604_800, resetAt: base.addingTimeInterval(300_000))
        DelayedBalanceURLProtocol.setHandler { _ in .init(data: Data("{}".utf8), statusCode: 200) }
        let published = PublicationRecorder()
        // Rendering hops to the main queue, so wait with expectations that spin the run loop.
        let pendingRender = PendingRender()
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(session: session,
                credentialReader: ProfileCredentialReader(email: "me@example.com"),
                parser: FixedOfficialQuotaParser(windows: [fiveHour, sevenDay])),
            actions: ProviderRefreshActions(
                currentProvider: { [repository] client in repository?.loadCurrent(appType: client.appType) },
                isActiveClient: { _ in true },
                render: { snapshot in published.recordRender(snapshot); pendingRender.fulfill() },
                storeClientSnapshot: { _, _, _ in },
                quickSwitchSummaryChanged: { _ in }),
            refreshPreferences: preferences, codexLocal: local, now: { clock.now })
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        func refresh(force: Bool = false, userInitiated: Bool = false) {
            let rendered = expectation(description: "codex snapshot rendered")
            pendingRender.expect(rendered)
            coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: force,
                switched: false, userInitiated: userInitiated)
            wait(for: [rendered], timeout: 3)
        }

        // 1. The first read after a source change always asks the server and starts the log source.
        refresh(force: true)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        XCTAssertEqual(published.rendered.last?.officialQuotaWindows.map(\.remaining), [80, 45])
        let deadline = Date().addingTimeInterval(3)
        while local.freshDisplay(accountKey: "me@example.com") == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        // 2. The next scheduled refresh is answered by the log: no request, the log's numbers.
        clock.advance(by: 60)
        refresh()
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1, "a fresh log makes wham/usage unnecessary")
        let fromLog = try XCTUnwrap(published.rendered.last)
        XCTAssertEqual(fromLog.officialQuotaWindows.map(\.remaining), [65, 85])
        XCTAssertEqual(fromLog.officialQuotaWindows.map(\.label), ["5-hour quota", "7-day quota"])

        // 3. A manual refresh always asks the server, even while the log is fresh.
        clock.advance(by: 5)
        coordinator.resetCadence()
        refresh(userInitiated: true)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
        XCTAssertEqual(published.rendered.last?.officialQuotaWindows.map(\.remaining), [80, 45])

        // 4. Once the newest logged event is older than two minutes the ordinary request logic resumes.
        clock.advance(by: 130)
        refresh()
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)
    }

    private func useClaudeOfficialProvider() throws -> CCSwitchProvider {
        try withDatabase { database in
            try execute(database, sql: "UPDATE providers SET name = 'Claude Official', category = 'official', settings_config = '{}', meta = '{}' WHERE app_type = 'claude'")
        }
        return try XCTUnwrap(repository.loadCurrent(appType: "claude"))
    }

    private static let claudeUsage = Data(#"{"five_hour":{"utilization":23,"resets_at":"2099-01-01T05:00:00Z"},"seven_day":{"utilization":41,"resets_at":"2099-01-07T00:00:00Z"}}"#.utf8)

    func testOfficialRefreshUsesUsageCreditsAndDoesNotCallResetCreditList() throws {
        try setCurrentProvider("codex-replacement")
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour quota",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day quota",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 7 * 86_400
        )
        let bankedReset = CodexBankedReset(cards: [
                CodexBankedResetCard(
                    id: "usage-card",
                    resetType: "codex_rate_limits",
                    titleText: tr(.keyCodexBankedResetFullResetTitle),
                    expiresAt: Date(timeIntervalSince1970: 1_700_086_400),
                    expiresText: "Expires later"
                )
            ])
        let requestLock = NSLock()
        var requestPaths: [String] = []
        DelayedBalanceURLProtocol.setHandler { request in
            requestLock.lock()
            requestPaths.append(request.url?.path ?? "")
            requestLock.unlock()
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertFalse((request.url?.path ?? "").contains("consume"))
            if request.url?.path == "/api/forecast" {
                XCTAssertEqual(request.url?.host, "codex-reset.com")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                return DelayedBalanceURLProtocol.Reply(
                    data: ResponseParsersTests.codexResetIssueJSON,
                    statusCode: 200
                )
            }
            return DelayedBalanceURLProtocol.Reply(
                data: Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#.utf8),
                statusCode: 200
            )
        }
        let rendered = expectation(description: "official snapshot with usage credits")
        rendered.expectedFulfillmentCount = 2
        var captured: Snapshot?
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: FixedOfficialQuotaParser(
                    windows: [fiveHour, sevenDay],
                    bankedReset: bankedReset
                )
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-banked-reset-usage"),
            actions: ProviderRefreshActions(
                currentProvider: { [repository] client in
                    repository?.loadCurrent(appType: client.appType)
                },
                isActiveClient: { _ in true },
                render: { snapshot in
                    captured = snapshot
                    rendered.fulfill()
                },
                storeClientSnapshot: { _, _, _ in },
                quickSwitchSummaryChanged: { _ in },
            )
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        wait(for: [rendered], timeout: 2)
        XCTAssertEqual(try XCTUnwrap(captured).officialQuotaWindows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(try XCTUnwrap(captured).bankedReset?.availableCount, 1)
        XCTAssertEqual(try XCTUnwrap(captured).resetForecast.probability24h, .percent(24))
        XCTAssertEqual(try XCTUnwrap(captured).resetForecast.probability48h, .percent(42))
        XCTAssertEqual(try XCTUnwrap(captured).resetForecast.confidence, .low)
        requestLock.lock()
        let paths = requestPaths
        requestLock.unlock()
        XCTAssertEqual(paths.filter { $0.contains("rate-limit-reset-credits") }, [])
        XCTAssertEqual(paths.filter { $0.contains("consume") }, [])
        XCTAssertTrue(paths.contains("/api/forecast"))
    }

    func testOfficialRefreshHidesBankedResetWhenCreditListFailsAndKeepsQuotaWindows() throws {
        try setCurrentProvider("codex-replacement")
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour quota",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day quota",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 7 * 86_400
        )
        let requestLock = NSLock()
        var requestPaths: [String] = []
        DelayedBalanceURLProtocol.setHandler { request in
            requestLock.lock()
            requestPaths.append(request.url?.path ?? "")
            requestLock.unlock()
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertFalse((request.url?.path ?? "").contains("consume"))
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                return DelayedBalanceURLProtocol.Reply(
                    data: Data(#"{"error":"fixture-list-unavailable"}"#.utf8),
                    statusCode: 500
                )
            }
            if request.url?.path == "/api/forecast" {
                return DelayedBalanceURLProtocol.Reply(
                    data: ResponseParsersTests.codexResetIssueJSON,
                    statusCode: 200
                )
            }
            return DelayedBalanceURLProtocol.Reply(
                data: Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#.utf8),
                statusCode: 200
            )
        }
        let rendered = expectation(description: "official snapshot after list failure")
        var captured: Snapshot?
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: FixedOfficialQuotaParser(
                    windows: [fiveHour, sevenDay],
                    bankedResetNeedsCreditList: true
                )
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-banked-reset-list-failure"),
            actions: ProviderRefreshActions(
                currentProvider: { [repository] client in
                    repository?.loadCurrent(appType: client.appType)
                },
                isActiveClient: { _ in true },
                render: { snapshot in
                    captured = snapshot
                    rendered.fulfill()
                },
                storeClientSnapshot: { _, _, _ in },
                quickSwitchSummaryChanged: { _ in },
            )
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        wait(for: [rendered], timeout: 2)
        let snapshot = try XCTUnwrap(captured)
        XCTAssertEqual(snapshot.officialQuotaWindows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(snapshot.officialQuotaWindows.map(\.remaining), [80, 45])
        XCTAssertNil(snapshot.bankedReset)
        XCTAssertEqual(snapshot.resetForecast, .unavailable)
        requestLock.lock()
        let paths = requestPaths
        requestLock.unlock()
        XCTAssertTrue(paths.contains { $0.contains("/backend-api/wham/usage") })
        XCTAssertTrue(paths.contains { $0.contains("/backend-api/wham/rate-limit-reset-credits") })
        XCTAssertFalse(paths.contains { $0.contains("consume") })
        XCTAssertFalse(paths.contains("/api/forecast"))
    }

    func testOfficialRefreshDrawsBankedResetDetailsFromReadOnlyCreditList() throws {
        try setCurrentProvider("codex-replacement")
        let fixedNow = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-03T01:32:00Z"))
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour quota",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day quota",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 7 * 86_400
        )
        DelayedBalanceURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertFalse((request.url?.path ?? "").contains("consume"))
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                return DelayedBalanceURLProtocol.Reply(
                    data: Data(#"{"available_count":1,"credits":[{"id":"RateLimitResetCredit_list","reset_type":"codex_rate_limits","status":"available","expires_at":"2026-10-04T01:32:00Z"}]}"#.utf8),
                    statusCode: 200
                )
            }
            if request.url?.path == "/api/forecast" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                return DelayedBalanceURLProtocol.Reply(
                    data: ResponseParsersTests.codexResetIssueJSON,
                    statusCode: 200
                )
            }
            return DelayedBalanceURLProtocol.Reply(
                data: Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#.utf8),
                statusCode: 200
            )
        }
        let rendered = expectation(description: "official snapshot after list success")
        rendered.expectedFulfillmentCount = 2
        var captured: Snapshot?
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: FixedOfficialQuotaParser(
                    windows: [fiveHour, sevenDay],
                    bankedResetNeedsCreditList: true
                )
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-banked-reset-list-success"),
            actions: ProviderRefreshActions(
                currentProvider: { [repository] client in
                    repository?.loadCurrent(appType: client.appType)
                },
                isActiveClient: { _ in true },
                render: { snapshot in
                    captured = snapshot
                    rendered.fulfill()
                },
                storeClientSnapshot: { _, _, _ in },
                quickSwitchSummaryChanged: { _ in },
            ),
            now: { fixedNow }
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        wait(for: [rendered], timeout: 2)
        let snapshot = try XCTUnwrap(captured)
        XCTAssertEqual(snapshot.officialQuotaWindows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(snapshot.bankedReset?.availableCount, 1)
        XCTAssertEqual(snapshot.bankedReset?.cards.first?.resetType, "codex_rate_limits")
        XCTAssertEqual(snapshot.resetForecast.probability24h, .percent(24))
        XCTAssertEqual(snapshot.resetForecast.probability48h, .percent(42))
        XCTAssertEqual(snapshot.resetForecast.confidence, .low)
    }

    func testOfficialRefreshKeepsBankedResetWhenForecastFails() throws {
        try setCurrentProvider("codex-replacement")
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour quota",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let bankedReset = CodexBankedReset(cards: [
                CodexBankedResetCard(
                    id: "usage-card",
                    resetType: "codex_rate_limits",
                    titleText: tr(.keyCodexBankedResetFullResetTitle),
                    expiresAt: Date(timeIntervalSince1970: 1_700_086_400),
                    expiresText: "Expires later"
                )
            ])
        DelayedBalanceURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/api/forecast" {
                return DelayedBalanceURLProtocol.Reply(
                    data: Data("{}".utf8),
                    statusCode: 500
                )
            }
            return DelayedBalanceURLProtocol.Reply(
                data: Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#.utf8),
                statusCode: 200
            )
        }
        let rendered = expectation(description: "official snapshot after forecast failure")
        rendered.expectedFulfillmentCount = 2
        var captured: Snapshot?
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: FixedOfficialQuotaParser(
                    windows: [fiveHour],
                    bankedReset: bankedReset
                )
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-forecast-failure"),
            actions: ProviderRefreshActions(
                currentProvider: { [repository] client in
                    repository?.loadCurrent(appType: client.appType)
                },
                isActiveClient: { _ in true },
                render: { snapshot in
                    captured = snapshot
                    rendered.fulfill()
                },
                storeClientSnapshot: { _, _, _ in },
                quickSwitchSummaryChanged: { _ in },
            )
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        wait(for: [rendered], timeout: 2)
        let snapshot = try XCTUnwrap(captured)
        XCTAssertEqual(snapshot.bankedReset?.availableCount, 1)
        XCTAssertEqual(snapshot.resetForecast, .unavailable)
        XCTAssertEqual(snapshot.resetForecast.probability24h.displayText, "--%")
        XCTAssertEqual(snapshot.resetForecast.confidence.displayText(), "--")
    }

    func testOfficialRefreshRendersQuotaBeforeForecastAndHonorsTenMinuteTTL() throws {
        try setCurrentProvider("codex-replacement")
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour quota",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let bankedReset = CodexBankedReset(cards: [
            CodexBankedResetCard(
                id: "usage-card",
                resetType: "codex_rate_limits",
                titleText: tr(.keyCodexBankedResetFullResetTitle),
                expiresAt: Date(timeIntervalSince1970: 1_700_086_400),
                expiresText: "Expires later"
            )
        ])
        let forecastStarted = DispatchSemaphore(value: 0)
        let releaseForecast = DispatchSemaphore(value: 0)
        let requestLock = NSLock()
        var forecastCount = 0
        DelayedBalanceURLProtocol.setHandler { request in
            if request.url?.path == "/api/forecast" {
                requestLock.lock()
                forecastCount += 1
                requestLock.unlock()
                forecastStarted.signal()
                releaseForecast.wait()
                return DelayedBalanceURLProtocol.Reply(
                    data: ResponseParsersTests.codexResetIssueJSON,
                    statusCode: 200
                )
            }
            return DelayedBalanceURLProtocol.Reply(
                data: Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#.utf8),
                statusCode: 200
            )
        }
        let firstQuota = expectation(description: "quota rendered before forecast")
        let firstForecast = expectation(description: "forecast filled after quota")
        let cached = expectation(description: "cached forecast reused")
        let refreshed = expectation(description: "ttl expired refetches")
        let snapshotLock = NSLock()
        var snapshots: [Snapshot] = []
        var phase = 0
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: FixedOfficialQuotaParser(
                    windows: [fiveHour],
                    bankedReset: bankedReset
                )
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-forecast-ttl"),
            actions: ProviderRefreshActions(
                currentProvider: { [repository] client in
                    repository?.loadCurrent(appType: client.appType)
                },
                isActiveClient: { _ in true },
                render: { snapshot in
                    snapshotLock.lock()
                    snapshots.append(snapshot)
                    let currentPhase = phase
                    if currentPhase == 0, snapshots.count == 1 {
                        snapshotLock.unlock()
                        firstQuota.fulfill()
                        return
                    }
                    if currentPhase == 0, snapshot.resetForecast.hasAnyValue {
                        phase = 1
                        snapshotLock.unlock()
                        firstForecast.fulfill()
                        return
                    }
                    if currentPhase == 1, snapshot.resetForecast.isCached {
                        phase = 2
                        snapshotLock.unlock()
                        cached.fulfill()
                        return
                    }
                    if currentPhase == 2,
                       snapshot.resetForecast.hasAnyValue,
                       !snapshot.resetForecast.isCached {
                        phase = 3
                        snapshotLock.unlock()
                        refreshed.fulfill()
                        return
                    }
                    snapshotLock.unlock()
                },
                storeClientSnapshot: { _, _, _ in },
                quickSwitchSummaryChanged: { _ in },
            ),
            now: { clock.now }
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        wait(for: [firstQuota], timeout: 2)
        snapshotLock.lock()
        let firstSnapshot = snapshots[0]
        snapshotLock.unlock()
        XCTAssertEqual(firstSnapshot.bankedReset?.availableCount, 1)
        XCTAssertEqual(firstSnapshot.resetForecast, .unavailable)
        XCTAssertEqual(forecastStarted.wait(timeout: .now() + 2), .success)
        releaseForecast.signal()
        wait(for: [firstForecast], timeout: 2)
        snapshotLock.lock()
        let filled = snapshots.last
        snapshotLock.unlock()
        XCTAssertEqual(filled?.resetForecast.probability24h, .percent(24))
        XCTAssertFalse(filled?.resetForecast.isCached ?? true)

        clock.advance(by: 60)
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        wait(for: [cached], timeout: 2)
        requestLock.lock()
        let countAfterCache = forecastCount
        requestLock.unlock()
        XCTAssertEqual(countAfterCache, 1)
        snapshotLock.lock()
        let cachedSnapshot = snapshots.last
        snapshotLock.unlock()
        XCTAssertEqual(cachedSnapshot?.resetForecast.probability24h, .percent(24))
        XCTAssertEqual(cachedSnapshot?.resetForecast.isCached, true)

        clock.advance(by: ProviderRefreshCoordinator.codexResetForecastTTL)
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        XCTAssertEqual(forecastStarted.wait(timeout: .now() + 2), .success)
        releaseForecast.signal()
        wait(for: [refreshed], timeout: 2)
        requestLock.lock()
        let countAfterTTL = forecastCount
        requestLock.unlock()
        XCTAssertEqual(countAfterTTL, 2)
        snapshotLock.lock()
        let refreshedSnapshot = snapshots.last
        snapshotLock.unlock()
        XCTAssertEqual(refreshedSnapshot?.resetForecast.isCached, false)
    }

    func testOfficialRefreshKeepsCachedForecastWhenLaterFetchFails() throws {
        try setCurrentProvider("codex-replacement")
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour quota",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let bankedReset = CodexBankedReset(cards: [
            CodexBankedResetCard(
                id: "usage-card",
                resetType: "codex_rate_limits",
                titleText: tr(.keyCodexBankedResetFullResetTitle),
                expiresAt: Date(timeIntervalSince1970: 1_700_086_400),
                expiresText: "Expires later"
            )
        ])
        let requestLock = NSLock()
        var forecastStatus = 200
        DelayedBalanceURLProtocol.setHandler { request in
            if request.url?.path == "/api/forecast" {
                requestLock.lock()
                let status = forecastStatus
                requestLock.unlock()
                return DelayedBalanceURLProtocol.Reply(
                    data: status == 200 ? ResponseParsersTests.codexResetIssueJSON : Data("{}".utf8),
                    statusCode: status
                )
            }
            return DelayedBalanceURLProtocol.Reply(
                data: Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#.utf8),
                statusCode: 200
            )
        }
        let first = expectation(description: "first forecast success")
        let fallback = expectation(description: "failed fetch keeps cache")
        first.expectedFulfillmentCount = 2
        fallback.expectedFulfillmentCount = 2
        let phaseLock = NSLock()
        var waitingForFallback = false
        var captured: Snapshot?
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: FixedOfficialQuotaParser(
                    windows: [fiveHour],
                    bankedReset: bankedReset
                )
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-forecast-cache-fallback"),
            actions: ProviderRefreshActions(
                currentProvider: { [repository] client in
                    repository?.loadCurrent(appType: client.appType)
                },
                isActiveClient: { _ in true },
                render: { snapshot in
                    captured = snapshot
                    phaseLock.lock()
                    let isFallback = waitingForFallback
                    phaseLock.unlock()
                    if isFallback {
                        fallback.fulfill()
                    } else {
                        first.fulfill()
                    }
                },
                storeClientSnapshot: { _, _, _ in },
                quickSwitchSummaryChanged: { _ in },
            ),
            now: { clock.now }
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        wait(for: [first], timeout: 2)
        XCTAssertEqual(captured?.resetForecast.probability24h, .percent(24))
        let updatedAt = captured?.resetForecast.updatedAt

        requestLock.lock()
        forecastStatus = 500
        requestLock.unlock()
        clock.advance(by: ProviderRefreshCoordinator.codexResetForecastTTL)
        phaseLock.lock()
        waitingForFallback = true
        phaseLock.unlock()
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        wait(for: [fallback], timeout: 2)
        XCTAssertEqual(captured?.resetForecast.probability24h, .percent(24))
        XCTAssertEqual(captured?.resetForecast.probability48h, .percent(42))
        XCTAssertEqual(captured?.resetForecast.updatedAt, updatedAt)
        XCTAssertEqual(captured?.resetForecast.isCached, true)
        XCTAssertEqual(captured?.bankedReset?.availableCount, 1)
    }

    func testQuickSwitchCadenceRetainsSixtySecondIntervalAndResetBehavior() throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let summaryUpdated = DispatchSemaphore(value: 0)
        let responseCounter = IncrementingCounter()
        DelayedBalanceURLProtocol.setHandler { _ in
            let amount = responseCounter.next()
            return DelayedBalanceURLProtocol.success(amount: "\(amount).00")
        }
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-quick-switch-cadence"),
            actions: makeActions { _ in summaryUpdated.signal() },
            now: { clock.now }
        )

        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        clock.advance(by: 59)
        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        clock.advance(by: 1)
        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)

        coordinator.resetCadence()
        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)
    }

    func testQuickSwitchCadenceIsTrackedPerClientAndFeedsNotificationSnapshots() throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let summaryUpdated = DispatchSemaphore(value: 0)
        let snapshotLock = NSLock()
        var snapshotClients: [AssistantClient] = []
        let responseCounter = IncrementingCounter()
        DelayedBalanceURLProtocol.setHandler { _ in
            let amount = responseCounter.next()
            return DelayedBalanceURLProtocol.success(amount: "\(amount).00")
        }
        let actions = ProviderRefreshActions(
            currentProvider: { [repository] client in
                repository?.loadCurrent(appType: client.appType)
            },
            isActiveClient: { client in
                client == .codex
            },
            render: { _ in },
            storeClientSnapshot: { _, _, _ in },
            quickSwitchSummaryChanged: { _ in summaryUpdated.signal() },
            notificationSnapshot: { client, _, _ in
                snapshotLock.lock()
                snapshotClients.append(client)
                snapshotLock.unlock()
            }
        )
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-quick-switch-per-client"),
            actions: actions,
            now: { clock.now }
        )

        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)

        coordinator.refreshQuickSwitchSummaries(force: false, for: .claude)
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)

        coordinator.refreshQuickSwitchSummaries(force: false, for: .grok)
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)

        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)

        clock.advance(by: 60)
        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 4)

        snapshotLock.lock()
        let clients = Set(snapshotClients)
        snapshotLock.unlock()
        XCTAssertEqual(clients, [.codex, .claude, .grok])
    }

    func testNotificationRefreshRequestsOnlyEnabledProviders() throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                INSERT INTO providers VALUES (
                    'claude-extra', 'Claude Extra',
                    '{"api_key":"fixture-key","base_url":"https://claude-extra.provider.test"}',
                    '{"usage_script":{"enabled":true,"accessToken":"fixture-key","baseUrl":"https://claude-extra.provider.test","code":"url: `{{baseUrl}}/usage`"}}',
                    'custom', 'https://claude-extra.provider.test', 'claude', 0, 2, 2
                );
                """
            )
        }
        let responseCounter = IncrementingCounter()
        DelayedBalanceURLProtocol.setHandler { _ in
            let amount = responseCounter.next()
            return DelayedBalanceURLProtocol.success(amount: "\(amount).00")
        }
        let summaryUpdated = DispatchSemaphore(value: 0)
        let snapshotLock = NSLock()
        var snapshotProviderIDs: [String] = []
        let actions = ProviderRefreshActions(
            currentProvider: { [repository] client in
                repository?.loadCurrent(appType: client.appType)
            },
            isActiveClient: { client in
                client == .codex
            },
            render: { _ in },
            storeClientSnapshot: { _, _, _ in },
            quickSwitchSummaryChanged: { _ in summaryUpdated.signal() },
            notificationSnapshot: { _, providerID, _ in
                snapshotLock.lock()
                snapshotProviderIDs.append(providerID)
                snapshotLock.unlock()
            }
        )
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-notification-enabled-providers"),
            actions: actions
        )

        coordinator.refreshQuickSwitchSummaries(force: true, for: .claude)
        waitForEvent(summaryUpdated)
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
        snapshotLock.lock()
        XCTAssertEqual(Set(snapshotProviderIDs), ["claude-custom", "claude-extra"])
        snapshotLock.unlock()

        coordinator.refreshQuickSwitchSummaries(
            force: true,
            for: .claude,
            providerIDs: ["claude-custom"]
        )
        waitForEvent(summaryUpdated)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)
        snapshotLock.lock()
        XCTAssertEqual(snapshotProviderIDs.last, "claude-custom")
        snapshotLock.unlock()
    }

    func testDisabledProviderWithPendingAlertStillRefreshesUntilRearm() throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                INSERT INTO providers VALUES (
                    'claude-extra', 'Claude Extra',
                    '{"api_key":"fixture-key","base_url":"https://claude-extra.provider.test"}',
                    '{"usage_script":{"enabled":true,"accessToken":"fixture-key","baseUrl":"https://claude-extra.provider.test","code":"url: `{{baseUrl}}/usage`"}}',
                    'custom', 'https://claude-extra.provider.test', 'claude', 0, 2, 2
                );
                """
            )
        }
        let notificationClient = RecordingBalanceNotificationClient()
        let suiteName = "ProviderRefreshCoordinatorTests.PendingRearm.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notifications = BalanceNotificationCoordinator(
            defaults: defaults,
            client: notificationClient
        )
        notifications.setGlobalEnabled(true)
        notifications.setAgentEnabled(true, agent: .claude)
        notifications.setProviderEnabled(true, agent: .claude, providerID: "claude-custom")
        notifications.setProviderEnabled(false, agent: .claude, providerID: "claude-extra")
        let balanceKey = BalanceNotificationResourceKey(
            agent: .claude,
            providerID: "claude-custom",
            resourceID: "balance"
        )
        notifications.updateRule(key: balanceKey, kind: .balance, unit: "USD") { rule in
            rule.firstThreshold = 20
            rule.secondEnabled = true
            rule.secondThreshold = 5
        }

        func balanceSnapshot(_ amount: Double) -> Snapshot {
            Snapshot.balance("Claude Custom", amount, "USD", nil, Date())
        }
        notifications.process(snapshot: balanceSnapshot(21), agent: .claude, providerID: "claude-custom")
        notifications.process(snapshot: balanceSnapshot(19), agent: .claude, providerID: "claude-custom")
        notifications.process(snapshot: balanceSnapshot(4), agent: .claude, providerID: "claude-custom")
        XCTAssertEqual(notificationClient.deliveries.count, 2)
        XCTAssertEqual(notifications.settings.rule(for: balanceKey)?.stage, .second)

        notifications.setProviderEnabled(false, agent: .claude, providerID: "claude-custom")
        let pending = notifications.monitoredNotificationTargets().first { $0.client == .claude }
        XCTAssertEqual(pending?.providerIDs, ["claude-custom"])

        let amounts = AmountQueue(["100.00", "15.00"])
        DelayedBalanceURLProtocol.setHandler { _ in
            DelayedBalanceURLProtocol.success(amount: amounts.next())
        }
        let processed = DispatchSemaphore(value: 0)
        let snapshotLock = NSLock()
        var snapshotProviderIDs: [String] = []
        let actions = ProviderRefreshActions(
            currentProvider: { [repository] client in
                repository?.loadCurrent(appType: client.appType)
            },
            isActiveClient: { client in
                client == .codex
            },
            render: { _ in },
            storeClientSnapshot: { _, _, _ in },
            quickSwitchSummaryChanged: { _ in },
            notificationSnapshot: { _, providerID, snapshot in
                notifications.process(
                    snapshot: snapshot,
                    agent: .claude,
                    providerID: providerID
                )
                snapshotLock.lock()
                snapshotProviderIDs.append(providerID)
                snapshotLock.unlock()
                processed.signal()
            }
        )
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-pending-rearm"),
            actions: actions
        )

        let target = try XCTUnwrap(notifications.monitoredNotificationTargets().first { $0.client == .claude })
        coordinator.refreshQuickSwitchSummaries(
            force: true,
            for: .claude,
            providerIDs: target.providerIDs
        )
        waitForEvent(processed)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        snapshotLock.lock()
        XCTAssertEqual(snapshotProviderIDs, ["claude-custom"])
        snapshotLock.unlock()
        XCTAssertEqual(notificationClient.deliveries.count, 2, "Provider OFF must not deliver during reset")
        XCTAssertEqual(notifications.settings.rule(for: balanceKey)?.stage, .normal)
        XCTAssertEqual(
            notifications.monitoredNotificationTargets().first { $0.client == .claude },
            nil
        )

        notifications.setProviderEnabled(true, agent: .claude, providerID: "claude-custom")
        let enabled = try XCTUnwrap(notifications.monitoredNotificationTargets().first { $0.client == .claude })
        XCTAssertEqual(enabled.providerIDs, ["claude-custom"])
        coordinator.refreshQuickSwitchSummaries(
            force: true,
            for: .claude,
            providerIDs: enabled.providerIDs
        )
        waitForEvent(processed)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
        XCTAssertEqual(notificationClient.deliveries.count, 3)
        XCTAssertEqual(notifications.settings.rule(for: balanceKey)?.stage, .first)
    }

    func testDisabledAgentWithPendingAlertStillRefreshesUntilRearm() throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                INSERT INTO providers VALUES (
                    'claude-extra', 'Claude Extra',
                    '{"api_key":"fixture-key","base_url":"https://claude-extra.provider.test"}',
                    '{"usage_script":{"enabled":true,"accessToken":"fixture-key","baseUrl":"https://claude-extra.provider.test","code":"url: `{{baseUrl}}/usage`"}}',
                    'custom', 'https://claude-extra.provider.test', 'claude', 0, 2, 2
                );
                """
            )
        }
        let notificationClient = RecordingBalanceNotificationClient()
        let suiteName = "ProviderRefreshCoordinatorTests.AgentPendingRearm.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notifications = BalanceNotificationCoordinator(
            defaults: defaults,
            client: notificationClient
        )
        notifications.setGlobalEnabled(true)
        notifications.setAgentEnabled(true, agent: .claude)
        notifications.setProviderEnabled(true, agent: .claude, providerID: "claude-custom")
        notifications.setProviderEnabled(false, agent: .claude, providerID: "claude-extra")
        let balanceKey = BalanceNotificationResourceKey(
            agent: .claude,
            providerID: "claude-custom",
            resourceID: "balance"
        )
        notifications.updateRule(key: balanceKey, kind: .balance, unit: "USD") { rule in
            rule.firstThreshold = 20
            rule.secondEnabled = true
            rule.secondThreshold = 5
        }

        func balanceSnapshot(_ amount: Double) -> Snapshot {
            Snapshot.balance("Claude Custom", amount, "USD", nil, Date())
        }
        notifications.process(snapshot: balanceSnapshot(21), agent: .claude, providerID: "claude-custom")
        notifications.process(snapshot: balanceSnapshot(19), agent: .claude, providerID: "claude-custom")
        notifications.process(snapshot: balanceSnapshot(4), agent: .claude, providerID: "claude-custom")
        XCTAssertEqual(notificationClient.deliveries.count, 2)
        XCTAssertEqual(notifications.settings.rule(for: balanceKey)?.stage, .second)

        notifications.setAgentEnabled(false, agent: .claude)
        let pending = notifications.monitoredNotificationTargets().first { $0.client == .claude }
        XCTAssertEqual(pending?.providerIDs, ["claude-custom"])
        XCTAssertFalse(pending?.providerIDs.contains("claude-extra") ?? true)

        let amounts = AmountQueue(["100.00", "15.00"])
        DelayedBalanceURLProtocol.setHandler { _ in
            DelayedBalanceURLProtocol.success(amount: amounts.next())
        }
        let processed = DispatchSemaphore(value: 0)
        let snapshotLock = NSLock()
        var snapshotProviderIDs: [String] = []
        let actions = ProviderRefreshActions(
            currentProvider: { [repository] client in
                repository?.loadCurrent(appType: client.appType)
            },
            isActiveClient: { client in
                client == .codex
            },
            render: { _ in },
            storeClientSnapshot: { _, _, _ in },
            quickSwitchSummaryChanged: { _ in },
            notificationSnapshot: { _, providerID, snapshot in
                notifications.process(
                    snapshot: snapshot,
                    agent: .claude,
                    providerID: providerID
                )
                snapshotLock.lock()
                snapshotProviderIDs.append(providerID)
                snapshotLock.unlock()
                processed.signal()
            }
        )
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-agent-pending-rearm"),
            actions: actions
        )

        let target = try XCTUnwrap(notifications.monitoredNotificationTargets().first { $0.client == .claude })
        coordinator.refreshQuickSwitchSummaries(
            force: true,
            for: .claude,
            providerIDs: target.providerIDs
        )
        waitForEvent(processed)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        snapshotLock.lock()
        XCTAssertEqual(snapshotProviderIDs, ["claude-custom"])
        snapshotLock.unlock()
        XCTAssertEqual(notificationClient.deliveries.count, 2, "Agent OFF must not deliver during reset")
        XCTAssertEqual(notifications.settings.rule(for: balanceKey)?.stage, .normal)
        XCTAssertEqual(
            notifications.monitoredNotificationTargets().first { $0.client == .claude },
            nil
        )

        notifications.setAgentEnabled(true, agent: .claude)
        let enabled = try XCTUnwrap(notifications.monitoredNotificationTargets().first { $0.client == .claude })
        XCTAssertEqual(enabled.providerIDs, ["claude-custom"])
        coordinator.refreshQuickSwitchSummaries(
            force: true,
            for: .claude,
            providerIDs: enabled.providerIDs
        )
        waitForEvent(processed)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
        XCTAssertEqual(notificationClient.deliveries.count, 3)
        XCTAssertEqual(notifications.settings.rule(for: balanceKey)?.stage, .first)
    }

    func testOfficialQuickSwitchSummaryReformatsCachedWindowsForPreferenceWithoutRefetching() throws {
        try setCurrentProvider("codex-replacement")
        DelayedBalanceURLProtocol.setHandler { _ in
            DelayedBalanceURLProtocol.success(amount: "0.00")
        }
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour quota",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day quota",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 7 * 86_400
        )
        let summaryUpdated = DispatchSemaphore(value: 0)
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: FixedOfficialQuotaParser(windows: [fiveHour, sevenDay])
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-official-quick-switch-presentation"),
            actions: makeActions { providerID in
                if providerID == "codex-replacement" {
                    summaryUpdated.signal()
                }
            }
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))

        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        waitForEvent(summaryUpdated)
        waitForCoordinator(coordinator)

        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        XCTAssertEqual(
            coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour)["codex-replacement"],
            "80% / 5 hours"
        )
        XCTAssertEqual(
            coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .sevenDay)["codex-replacement"],
            "45% / 7 days"
        )
        // Reformatting the same cached payload for the other preference is
        // presentation-only and must not start another quota request.
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
    }

    func testQuickSwitchOfficialCallbackUsesStructuredWindowsAndPreservesBalanceSummary() throws {
        DelayedBalanceURLProtocol.setHandler { _ in
            DelayedBalanceURLProtocol.success(amount: "28.00", unit: "USD")
        }
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour quota",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day quota",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 7 * 86_400
        )
        let officialUpdated = DispatchSemaphore(value: 0)
        let balanceUpdated = DispatchSemaphore(value: 0)
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: FixedOfficialQuotaParser(windows: [fiveHour, sevenDay])
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-quick-switch-official-payload"),
            actions: makeActions { providerID in
                switch providerID {
                case "codex-replacement": officialUpdated.signal()
                case "codex-custom": balanceUpdated.signal()
                default: break
                }
            }
        )

        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex)
        waitForEvent(officialUpdated)
        waitForEvent(balanceUpdated)
        waitForCoordinator(coordinator)

        let fiveHourSummaries = coordinator.quickSwitchSummariesSnapshot(
            preferredQuotaWindow: .fiveHour
        )
        let sevenDaySummaries = coordinator.quickSwitchSummariesSnapshot(
            preferredQuotaWindow: .sevenDay
        )
        XCTAssertEqual(fiveHourSummaries["codex-replacement"], "80% / 5 hours")
        XCTAssertEqual(sevenDaySummaries["codex-replacement"], "45% / 7 days")
        XCTAssertEqual(sevenDaySummaries["codex-custom"], fiveHourSummaries["codex-custom"])
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
    }

    func testQuickSwitchOfficialLateResponseIsDroppedAfterSameTokenConfigurationChange() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DelayedBalanceURLProtocol.setHandler { request in
            if request.url?.path.contains("wham/usage") == true {
                started.signal()
                return .init(data: Data(), statusCode: 200, delayUntil: release)
            }
            return DelayedBalanceURLProtocol.success(amount: "28.00")
        }
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour, remaining: 80, label: "5-hour quota", daysText: "5 hours",
            reset: "5h", durationSeconds: 5 * 3_600
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay, remaining: 45, label: "7-day quota", daysText: "7 days",
            reset: "7d", durationSeconds: 7 * 86_400
        )
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: FixedOfficialQuotaParser(windows: [fiveHour, sevenDay])
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            actions: makeActions()
        )
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        waitForCoordinator(coordinator)
        // This test owns response ordering, not concurrent SQLite writers.
        // Mutate on the owner queue while the old transport is still gated.
        let changedConfiguration = expectation(description: "official revision changed while request pending")
        var mutationError: Error?
        coordinator.performAsync {
            do {
                try self.withDatabase { db in
                    try self.execute(db, sql: "UPDATE providers SET name='Renamed Official' WHERE id='codex-replacement'")
                }
            } catch { mutationError = error }
            changedConfiguration.fulfill()
        }
        wait(for: [changedConfiguration], timeout: 2)
        if let mutationError { throw mutationError }
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, configurationChanged: true)
        release.signal()
        waitForCoordinator(coordinator)
        XCTAssertNil(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour, client: .codex)["codex-replacement"])
    }

    func testOfficialQuickSwitchSummaryUsesSafeFallbacksAndDoesNotKeepStaleMissingWindow() throws {
        try setCurrentProvider("codex-replacement")
        DelayedBalanceURLProtocol.setHandler { _ in
            DelayedBalanceURLProtocol.success(amount: "0.00")
        }
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour quota",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day quota",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 7 * 86_400
        )
        let windows = MutableOfficialQuotaWindows([fiveHour, sevenDay])
        let summaryUpdated = DispatchSemaphore(value: 0)
        let coordinator = makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(
                session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
                parser: MutableOfficialQuotaParser(windows: windows)
            ),
            balanceAPIClient: BalanceAPIClient(session: session),
            queue: DispatchQueue(label: "test.provider-refresh-official-quick-switch-fallback"),
            actions: makeActions { providerID in
                if providerID == "codex-replacement" {
                    summaryUpdated.signal()
                }
            }
        )
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))

        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: true,
            switched: false
        )
        waitForEvent(summaryUpdated)
        waitForCoordinator(coordinator)

        windows.set([sevenDay])
        coordinator.resetCadence()
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForEvent(summaryUpdated)
        waitForCoordinator(coordinator)
        XCTAssertEqual(
            coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour)["codex-replacement"],
            "45% / 7 days"
        )

        windows.set([fiveHour])
        coordinator.resetCadence()
        coordinator.refreshStandardProvider(
            current: current,
            client: .codex,
            forceBalance: false,
            switched: false
        )
        waitForEvent(summaryUpdated)
        waitForCoordinator(coordinator)
        XCTAssertEqual(
            coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour)["codex-replacement"],
            "80% / 5 hours"
        )
        XCTAssertNil(
            coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .sevenDay)["codex-replacement"]
        )
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)
    }


    func testOfficialObservationDetectsResetRestoresAfterRestartAndClearsAtEpisodeBoundaries() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        var coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .watching)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .observed)
        coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .observed)

        fixture.update { $0.forecast = ObservationFixture.forecast(episode: "second") }
        clock.advance(by: ProviderRefreshCoordinator.codexResetForecastTTL + 1)
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .notEligible)
        fixture.update { $0.windows = ObservationFixture.windows(70, 80, cycle: 2) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .watching)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 3) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .observed)
        fixture.update { $0.forecast = ObservationFixture.forecast(episode: nil, signal: false) }
        clock.advance(by: ProviderRefreshCoordinator.codexResetForecastTTL + 1)
        let ended = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        XCTAssertNil(ended.resetForecast.officialSignal)
        XCTAssertNil(store.load(providerID: "codex-replacement", accountKey: "a@example.com"))
    }

    func testOfficialObservationDoesNotConfirmUnusedFullQuotasOrSingleWindowRecovery() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 1) }
        let coordinator = try observationCoordinator(fixture, store: observationStore())
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .notEligible)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .notEligible)
        fixture.update { $0.windows = ObservationFixture.windows(80, 90, cycle: 2) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .watching)
        fixture.update { $0.windows = ObservationFixture.windows(100, 90, cycle: 3) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .watching)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 3) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .watching)
    }

    func testOfficialObservationIgnoresPartialAndFailedQuotaResponses() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let coordinator = try observationCoordinator(fixture, store: store)
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        let previous = try XCTUnwrap(store.load(providerID: "codex-replacement", accountKey: "a@example.com")).observation.previousSample
        fixture.update { $0.windows = Array(ObservationFixture.windows(100, 100, cycle: 2).prefix(1)) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .watching)
        XCTAssertEqual(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation.previousSample, previous)
        fixture.update { $0.quotaStatus = 503 }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).kind, .error)
        XCTAssertEqual(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation.previousSample, previous)
        fixture.update { $0.quotaStatus = 200; $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .observed)
    }

    func testOfficialObservationDropsLateAccountAResponseAndStartsAccountBIndependently() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let coordinator = try observationCoordinator(fixture, store: store)
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        let previous = store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.update {
            $0.windows = ObservationFixture.windows(100, 100, cycle: 2)
            $0.quotaGate = (started, release)
        }
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: true, switched: false)
        waitForEvent(started)
        XCTAssertEqual(fixture.lastAuthorization, "Bearer token-a@example.com")
        fixture.update {
            $0.email = "b@example.com"
            $0.windows = ObservationFixture.windows(100, 100, cycle: 3)
            $0.quotaGate = nil
        }
        let rendered = expectation(description: "only account B response renders")
        var snapshots: [Snapshot] = []
        fixture.onRender = { snapshots.append($0); rendered.fulfill() }
        // Register B while A is still in flight: they must use distinct transports.
        coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: true, switched: false)
        waitForCoordinator(coordinator)
        release.signal()
        wait(for: [rendered], timeout: 3)
        waitForCoordinator(coordinator)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.officialQuotaWindows, ObservationFixture.windows(100, 100, cycle: 3))
        XCTAssertEqual(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation, previous)
        let b = try XCTUnwrap(store.load(providerID: "codex-replacement", accountKey: "b@example.com"))
        XCTAssertEqual(b.observation.state, .notEligible)
        XCTAssertEqual(b.observation.previousSample, CodexResetQuotaSample.make(from: ObservationFixture.windows(100, 100, cycle: 3)))

    }

    func testAnonymousOfficialSignalNeverRestoresObservedStateAcrossRestart() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.forecast = ObservationFixture.forecast(episode: nil) }
        let store = try observationStore()
        var coordinator = try observationCoordinator(fixture, store: store)
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .watching)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .observed)
        XCTAssertNil(store.load(providerID: "codex-replacement", accountKey: "a@example.com"))
        // Also reject the anonymous entry written by previous versions.
        var legacy = CodexResetObservation()
        legacy.observe(try XCTUnwrap(CodexResetQuotaSample.make(from: ObservationFixture.windows(70, 80, cycle: 1))), now: Date())
        legacy.observe(try XCTUnwrap(CodexResetQuotaSample.make(from: ObservationFixture.windows(100, 100, cycle: 2))), now: Date())
        store.save(providerID: "codex-replacement", accountKey: "a@example.com", episodeKey: "active", observation: legacy)
        coordinator = try observationCoordinator(fixture, store: store)
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .notEligible)
        XCTAssertNil(store.load(providerID: "codex-replacement", accountKey: "a@example.com"))
    }

    func testOfficialObservationSurvivesCreditFailureAndPresentsWithoutCards() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let coordinator = try observationCoordinator(fixture, store: store)
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.update {
            $0.windows = ObservationFixture.windows(100, 100, cycle: 2)
            $0.needsCreditList = true
            $0.creditGate = (started, release)
        }
        let rendered = expectation(description: "credit failure still renders observation")
        var snapshot: Snapshot?
        fixture.onRender = { snapshot = $0; rendered.fulfill() }
        coordinator.refreshStandardProvider(current: try XCTUnwrap(repository.loadCurrent(appType: "codex")), client: .codex, forceBalance: true, switched: false)
        waitForEvent(started)
        waitForCoordinator(coordinator)
        XCTAssertEqual(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation.state, .observed)
        release.signal()
        wait(for: [rendered], timeout: 2)
        let result = try XCTUnwrap(snapshot)
        XCTAssertNil(result.bankedReset)
        XCTAssertTrue(result.resetForecast.isOfficialResetConfirmed)
        XCTAssertTrue(result.officialQuotaMenuPresentation(lunaReserveDisplayMode: .disabled, hideExhaustedQuota: false).resetForecast.isOfficialResetConfirmed)
        XCTAssertEqual(result.officialQuotaWindows, ObservationFixture.windows(100, 100, cycle: 2))
        XCTAssertEqual(fixture.forecastRequestCount, 1)
    }

    func testUnavailableAndFailedForecastRetrySoonerThanSuccessfulCacheExpires() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.forecast = Data("{}".utf8) }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: observationStore(), clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        XCTAssertEqual(fixture.forecastRequestCount, 1)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: ProviderRefreshCoordinator.codexResetForecastRetryInterval - 1)
        _ = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(fixture.forecastRequestCount, 1)
        clock.advance(by: 1)
        fixture.update { $0.forecastStatus = 503 }
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        XCTAssertEqual(fixture.forecastRequestCount, 2)
        _ = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(fixture.forecastRequestCount, 2)
        clock.advance(by: ProviderRefreshCoordinator.codexResetForecastRetryInterval)
        fixture.update { $0.forecastStatus = 200; $0.forecast = ObservationFixture.forecast(episode: "recovered") }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .watching)
        XCTAssertEqual(fixture.forecastRequestCount, 3)
        clock.advance(by: ProviderRefreshCoordinator.codexResetForecastRetryInterval)
        _ = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(fixture.forecastRequestCount, 3, "successful forecast keeps its ten-minute cache")
    }

    func testForecastRecoveryBeforeResetRetainsConsumptionEvidence() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.forecastStatus = 503 }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: observationStore(), clock: clock)
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast, .unavailable)

        // T+1 minute: signal becomes available while both quotas still show usage.
        clock.advance(by: 60)
        fixture.update { $0.forecastStatus = 200 }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .watching)
        XCTAssertEqual(fixture.forecastRequestCount, 2)

        // T+3 minutes: the same episode resets. The successful cache is sufficient.
        clock.advance(by: 120)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialResetObservation, .observed)
        XCTAssertEqual(fixture.forecastRequestCount, 2)
    }

    func testStandardAndQuickSwitchShareLocalCredentialQuotaTransport() throws {
        let fixture = ObservationFixture()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.update { $0.hasBankedReset = false; $0.quotaGate = (started, release) }
        let coordinator = try observationCoordinator(fixture, store: observationStore())
        let rendered = expectation(description: "standard consumer receives shared result")
        let summary = expectation(description: "quick switch consumer receives shared result")
        fixture.onRender = { _ in rendered.fulfill() }
        fixture.onSummary = { summary.fulfill() }
        coordinator.refreshStandardProvider(current: try XCTUnwrap(repository.loadCurrent(appType: "codex")), client: .codex, forceBalance: true, switched: false)
        waitForEvent(started)
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: ["codex-replacement"])
        waitForCoordinator(coordinator)
        release.signal()
        wait(for: [rendered, summary], timeout: 3)
        XCTAssertEqual(fixture.quotaRequestCount, 1)
        XCTAssertEqual(fixture.forecastRequestCount, 0)
        XCTAssertEqual(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour)["codex-replacement"], "70% / 5h")
    }

    func testStandardAndQuickSwitchKeepDifferentAccountsInSeparateTransports() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.update { $0.hasBankedReset = false; $0.quotaGate = (started, release) }
        let coordinator = try observationCoordinator(fixture, store: store)
        let summary = expectation(description: "only B result updates summary")
        fixture.onSummary = { summary.fulfill() }
        coordinator.refreshStandardProvider(current: try XCTUnwrap(repository.loadCurrent(appType: "codex")), client: .codex, forceBalance: true, switched: false)
        waitForEvent(started)
        fixture.update {
            $0.email = "b@example.com"
            $0.windows = ObservationFixture.windows(100, 100, cycle: 2)
            $0.quotaGate = nil
        }
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: ["codex-replacement"])
        waitForCoordinator(coordinator)
        release.signal()
        wait(for: [summary], timeout: 3)
        waitForCoordinator(coordinator)
        XCTAssertEqual(fixture.quotaRequestCount, 2)
        XCTAssertEqual(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour)["codex-replacement"], "100% / 5h")
        XCTAssertNil(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com"))
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "b@example.com")?.previousSample, CodexResetQuotaSample.make(from: ObservationFixture.windows(100, 100, cycle: 2)))
    }

    func testQuickSwitchStoredTokenChangeDiscardsOldAccountResponse() throws {
        func setToken(_ token: String) throws {
            try withDatabase { database in
                try execute(database, sql: "UPDATE providers SET settings_config = '{\"auth\":{\"tokens\":{\"access_token\":\"\(token)\"}}}' WHERE id = 'codex-replacement'")
            }
        }
        let fixture = ObservationFixture()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.update { $0.quotaGate = (started, release); $0.hasBankedReset = false }
        let coordinator = try observationCoordinator(fixture, store: observationStore())
        try setToken("stored-A")
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: ["codex-replacement"])
        waitForEvent(started)
        try setToken("stored-B")
        fixture.update { $0.quotaGate = nil; $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        let summary = expectation(description: "B summary")
        fixture.onSummary = { summary.fulfill() }
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: ["codex-replacement"])
        wait(for: [summary], timeout: 3)
        XCTAssertEqual(fixture.quotaRequestCount, 2)
        XCTAssertEqual(fixture.lastAuthorization, "Bearer stored-B")
        let stale = expectation(description: "A must not publish")
        stale.isInverted = true
        fixture.onSummary = { stale.fulfill() }
        release.signal()
        wait(for: [stale], timeout: 0.3)
        waitForCoordinator(coordinator)
        XCTAssertEqual(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour)["codex-replacement"], "100% / 5h")
    }

    func testColdStartCreditFailuresPersistQuotaEvidenceUntilSignalCanBeFetched() throws {
        let fixture = ObservationFixture()
        fixture.update {
            $0.hasBankedReset = false; $0.needsCreditList = true
            $0.forecast = ObservationFixture.forecast(episode: "first", publishedAt: Date(timeIntervalSince1970: 1_799_999_999))
        }
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        var coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast, .unavailable)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")?.state, .watching)
        XCTAssertEqual(fixture.forecastRequestCount, 0)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).resetForecast, .unavailable)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")?.state, .observed)
        XCTAssertEqual(fixture.forecastRequestCount, 0)
        // Forecast can recover much later; evidence remains within the current quota cycle.
        clock.advance(by: 3_600)
        fixture.update { $0.hasBankedReset = true; $0.needsCreditList = false }
        coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        let recovered = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        XCTAssertTrue(recovered.resetForecast.isOfficialResetConfirmed)
        XCTAssertEqual(fixture.forecastRequestCount, 1)
    }

    func testColdStartNoCardsQuotaJournalDoesNotAdvanceOnPartialOrFailedSnapshots() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.hasBankedReset = false }
        let store = try observationStore()
        let coordinator = try observationCoordinator(fixture, store: store)
        _ = try observationRefresh(coordinator, fixture: fixture)
        let trusted = store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")
        fixture.update { $0.windows = Array(ObservationFixture.windows(100, 100, cycle: 2).prefix(1)) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com"), trusted)
        fixture.update { $0.quotaStatus = 503 }
        _ = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com"), trusted)
        fixture.update { $0.quotaStatus = 200; $0.email = "b@example.com"; $0.windows = ObservationFixture.windows(100, 100, cycle: 2); $0.hasBankedReset = true }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .notEligible)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com"), trusted)
    }

    func testUnassignedResetEvidenceDoesNotConfirmSignalPublishedAfterReset() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.hasBankedReset = false }
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 60)
        var object = try JSONSerialization.jsonObject(with: ObservationFixture.forecast(episode: "later")) as! [String: Any]
        var signal = object["official_signal"] as! [String: Any]
        signal["at"] = ISO8601DateFormatter().string(from: clock.now)
        object["official_signal"] = signal
        let data = try JSONSerialization.data(withJSONObject: object)
        fixture.update { $0.hasBankedReset = true; $0.forecast = data }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .notEligible)
    }

    func testAnonymousSignalDoesNotRestoreUnassignedResetEvidence() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.hasBankedReset = false; $0.forecast = ObservationFixture.forecast(episode: nil) }
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        var coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        fixture.update { $0.hasBankedReset = true }
        coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .notEligible)
    }

    func testExpiredUnassignedQuotaCycleCannotConfirmANewSignal() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.hasBankedReset = false }
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        var coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 604_801)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2); $0.hasBankedReset = true }
        coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .notEligible)
    }

    func testCachedOrdinaryForecastDoesNotEraseEvidenceBeforeFirstSignal() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.forecast = ObservationFixture.forecast(episode: nil, signal: false) }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: observationStore(), clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        let published = clock.now.addingTimeInterval(60)
        clock.advance(by: 90)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 90)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertNil(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialSignal)
        clock.advance(by: 421)
        fixture.update { $0.forecast = ObservationFixture.forecast(episode: "first", publishedAt: published) }
        XCTAssertTrue(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.isOfficialResetConfirmed)
        XCTAssertEqual(fixture.forecastRequestCount, 2)
    }

    func testNewSignalCanAdoptProvisionalCachedEventOnlyWithinPublicationWindow() throws {
        for (publicationOffset, validateA) in [(60.0, false), (240.0, false), (60.0, true)] {
            let fixture = ObservationFixture()
            let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
            let store = try observationStore()
            let coordinator = try observationCoordinator(fixture, store: store, clock: clock)
            _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
            let published = clock.now.addingTimeInterval(publicationOffset)
            clock.advance(by: 120)
            _ = try observationRefresh(coordinator, fixture: fixture)
            clock.advance(by: 60)
            fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
            _ = try observationRefresh(coordinator, fixture: fixture)
            XCTAssertNil(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation.confirmedDetectedAt)
            clock.advance(by: 421)
            if validateA {
                _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
                let observation = try XCTUnwrap(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation)
                XCTAssertEqual(observation.confirmedDetectedAt, observation.detectedAt)
                XCTAssertNotNil(observation.confirmedDetectedAt)
                clock.advance(by: 601)
            }
            fixture.update { $0.forecast = ObservationFixture.forecast(episode: "second", publishedAt: published) }
            let result = try observationRefresh(coordinator, fixture: fixture, renders: 2)
            XCTAssertEqual(result.resetForecast.isOfficialResetConfirmed, publicationOffset < 120 && !validateA)
            XCTAssertEqual(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.episodeKey, "tweet_id:second")
        }
    }

    func testStableUndatedSignalDoesNotAdoptHistoricalResetEvidence() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.hasBankedReset = false }
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        var coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")?.state, .observed)
        fixture.update { $0.hasBankedReset = true; $0.forecast = ObservationFixture.forecast(episode: "undated-new") }
        coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        XCTAssertFalse(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.isOfficialResetConfirmed)
        fixture.update { $0.windows = ObservationFixture.windows(70, 80, cycle: 2) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 3) }
        XCTAssertTrue(try observationRefresh(coordinator, fixture: fixture).resetForecast.isOfficialResetConfirmed)
    }

    func testDatedSignalCannotAdoptTransitionWhoseBaselinePredatesPublication() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.hasBankedReset = false }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: observationStore(), clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 60)
        let publication = clock.now
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        fixture.update { $0.hasBankedReset = true; $0.forecast = ObservationFixture.forecast(episode: "new", publishedAt: publication) }
        XCTAssertFalse(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.isOfficialResetConfirmed)
    }

    func testNewSignalDoesNotInheritConsumptionOnlySeenBeforePublication() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.hasBankedReset = false }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: observationStore(), clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 60)
        let publication = clock.now
        clock.advance(by: 60)
        fixture.update {
            $0.windows = ObservationFixture.windows(100, 100, cycle: 1)
            $0.hasBankedReset = true
            $0.forecast = ObservationFixture.forecast(episode: "new", publishedAt: publication)
        }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.officialResetObservation, .notEligible)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertFalse(try observationRefresh(coordinator, fixture: fixture).resetForecast.isOfficialResetConfirmed)
    }

    func testQuotaJournalPreservesRolloverAtExpiredResetTimeUntilForecastRecovers() throws {
        let fixture = ObservationFixture()
        fixture.update {
            $0.hasBankedReset = false
            $0.forecast = ObservationFixture.forecast(episode: "rollover", publishedAt: Date(timeIntervalSince1970: 1_799_999_999))
        }
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        var coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 604_860)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")?.state, .observed)
        clock.advance(by: 60)
        fixture.update { $0.hasBankedReset = true }
        XCTAssertTrue(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.isOfficialResetConfirmed)
    }

    func testLateCreditReplyWithIdenticalQuotaCannotReplaceNewerCards() throws {
        let fixture = ObservationFixture()
        let coordinator = try observationCoordinator(fixture, store: observationStore())
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.update { $0.needsCreditList = true; $0.creditGate = (started, release) }
        coordinator.refreshStandardProvider(current: try XCTUnwrap(repository.loadCurrent(appType: "codex")), client: .codex, forceBalance: true, switched: false)
        waitForEvent(started)
        fixture.update { $0.needsCreditList = false; $0.creditGate = nil }
        XCTAssertNotNil(try observationRefresh(coordinator, fixture: fixture).bankedReset)
        let stale = expectation(description: "same quota older credit response must not render")
        stale.isInverted = true
        fixture.onRender = { _ in stale.fulfill() }
        release.signal()
        wait(for: [stale], timeout: 0.3)
        waitForCoordinator(coordinator)
    }

    func testUsageAfterProvisionalResetDoesNotEraseEventBeforeFreshB() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        clock.advance(by: 60)
        let publicationB = clock.now
        clock.advance(by: 60)
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        let event = try XCTUnwrap(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")?.detectedAt)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(80, 90, cycle: 2) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")?.detectedAt, event)
        clock.advance(by: 361)
        fixture.update { $0.forecast = ObservationFixture.forecast(episode: "B", publishedAt: publicationB) }
        XCTAssertTrue(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.isOfficialResetConfirmed)
    }

    func testNewQuotaEventDuringCachedAIsNotPinnedToAsEarlierDetectedAt() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertTrue(try observationRefresh(coordinator, fixture: fixture).resetForecast.isOfficialResetConfirmed)
        let oldDetected = store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation.detectedAt
        clock.advance(by: 60)
        let publicationB = clock.now
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(70, 80, cycle: 2) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        clock.advance(by: 60)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 3) }
        _ = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertNotEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")?.detectedAt, oldDetected)
        clock.advance(by: 361)
        fixture.update { $0.forecastStatus = 503 }
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        clock.advance(by: 60)
        fixture.update { $0.forecastStatus = 200; $0.forecast = ObservationFixture.forecast(episode: "B", publishedAt: publicationB) }
        XCTAssertTrue(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.isOfficialResetConfirmed)
        XCTAssertEqual(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.episodeKey, "tweet_id:B")
    }

    func testLateCreditReplyCannotOverwriteNewerQuotaFailureOrAdvanceObservation() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        clock.advance(by: 601)
        fixture.update {
            $0.needsCreditList = true; $0.creditGate = (started, release)
            $0.windows = ObservationFixture.windows(100, 100, cycle: 2)
        }
        coordinator.refreshStandardProvider(current: try XCTUnwrap(repository.loadCurrent(appType: "codex")), client: .codex, forceBalance: true, switched: false)
        waitForEvent(started)
        fixture.update { $0.quotaStatus = 503; $0.needsCreditList = false; $0.creditGate = nil }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).kind, .error)
        let trusted = store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation
        let journal = store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")
        let forecastRequests = fixture.forecastRequestCount
        let stale = expectation(description: "old credits cannot overwrite latest error")
        stale.isInverted = true
        fixture.onRender = { _ in stale.fulfill() }
        release.signal()
        wait(for: [stale], timeout: 0.3)
        waitForCoordinator(coordinator)
        XCTAssertEqual(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation, trusted)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com"), journal)
        XCTAssertEqual(fixture.forecastRequestCount, forecastRequests)
        fixture.update { $0.quotaStatus = 200 }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture, renders: 2).kind, .official)
    }

    func testLateCreditReplyCannotRewindNewerQuotaEvidenceOrRender() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.update { $0.needsCreditList = true; $0.creditGate = (started, release) }
        coordinator.refreshStandardProvider(current: try XCTUnwrap(repository.loadCurrent(appType: "codex")), client: .codex, forceBalance: true, switched: false)
        waitForEvent(started)
        fixture.update {
            $0.needsCreditList = false
            $0.creditGate = nil
            $0.windows = ObservationFixture.windows(100, 100, cycle: 2)
        }
        XCTAssertTrue(try observationRefresh(coordinator, fixture: fixture).resetForecast.isOfficialResetConfirmed)
        let trusted = store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation
        let journal = store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")
        let stale = expectation(description: "late older quota must not render")
        stale.isInverted = true
        fixture.onRender = { _ in stale.fulfill() }
        release.signal()
        wait(for: [stale], timeout: 0.3)
        waitForCoordinator(coordinator)
        XCTAssertEqual(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.observation, trusted)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com"), journal)
    }

    private func predictionWindows(now: Date, five: Double = 40, seven: Double = 40,
                                   weeklyReset: Date? = nil) -> [OfficialQuotaWindow] {
        [.init(kind: .fiveHour, remaining: five, label: "5h", daysText: "5h", reset: nil,
            durationSeconds: 18_000, resetAt: now.addingTimeInterval(9000)),
         .init(kind: .sevenDay, remaining: seven, label: "7d", daysText: "7d", reset: nil,
            durationSeconds: 604_800, resetAt: weeklyReset ?? now.addingTimeInterval(300_000))]
    }

    func testPredictionContextsUseQuotaJournalWithoutForecastAndDeduplicateResetOnRestart() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(date: base)
        fixture.update { $0.windows = predictionWindows(now: base); $0.hasBankedReset = false; $0.forecastStatus = 503 }
        var coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        let first = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(first.quotaPredictionAccountKey, "a@example.com")
        XCTAssertEqual(first.quotaPredictionContexts.compactMap(\.inferredCycleStart).count, 2)
        XCTAssertEqual(fixture.forecastRequestCount, 0)
        clock.advance(by: 1)
        let reset = base.addingTimeInterval(604_800)
        fixture.update { $0.windows = predictionWindows(now: base, five: 100, seven: 100, weeklyReset: reset) }
        let refreshed = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertNil(refreshed.quotaPredictionContexts.first { $0.cycle.kind == .fiveHour }?.inferredCycleStart)
        XCTAssertEqual(refreshed.quotaPredictionContexts.first { $0.cycle.kind == .sevenDay }?.inferredCycleStart, base)
        XCTAssertEqual(store.loadQuotaEvidence(providerID: "codex-replacement", accountKey: "a@example.com")?.state, .observed)
        XCTAssertFalse(refreshed.resetForecast.isOfficialResetConfirmed, "No announcement request is required for prediction invalidation")
        // Recreate coordinator as at restart; the same journal event must not re-invalidate a new cycle.
        clock.advance(by: 18_144)
        fixture.update { $0.windows = predictionWindows(now: base, five: 100, seven: 90, weeklyReset: reset) }
        coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        let resumed = try observationRefresh(coordinator, fixture: fixture)
        let weekly = try XCTUnwrap(resumed.quotaPredictionContexts.first { $0.cycle.kind == .sevenDay })
        XCTAssertEqual(weekly.inferredCycleStart, base)
        XCTAssertNotNil(OfficialQuotaUsagePrediction.make(for: resumed.officialQuotaWindows[1], cycleStart: weekly.inferredCycleStart, now: clock.now))
        XCTAssertEqual(fixture.forecastRequestCount, 0)
    }

    func testPredictionRefillPersistsThroughFailuresPartialWindowsAndAccountSwitch() throws {
        let fixture = ObservationFixture()
        let store = try observationStore()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(date: base)
        fixture.update { $0.windows = predictionWindows(now: base); $0.hasBankedReset = false }
        var coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        _ = try observationRefresh(coordinator, fixture: fixture)
        fixture.update { $0.windows = predictionWindows(now: base, five: 60, seven: 30) }
        let refill = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertNil(refill.quotaPredictionContexts.first { $0.cycle.kind == .fiveHour }?.inferredCycleStart)
        XCTAssertNotNil(refill.quotaPredictionContexts.first { $0.cycle.kind == .sevenDay }?.inferredCycleStart)
        fixture.update { $0.quotaStatus = 503 }
        XCTAssertEqual(try observationRefresh(coordinator, fixture: fixture).kind, .error)
        fixture.update { $0.quotaStatus = 200; $0.windows = [predictionWindows(now: base, five: 55)[0]] }
        coordinator = try observationCoordinator(fixture, store: store, clock: clock)
        XCTAssertNil(try observationRefresh(coordinator, fixture: fixture).quotaPredictionContexts.first?.inferredCycleStart)
        fixture.update { $0.email = "b@example.com" }
        let other = try observationRefresh(coordinator, fixture: fixture)
        XCTAssertEqual(other.quotaPredictionAccountKey, "b@example.com")
        XCTAssertNotNil(other.quotaPredictionContexts.first?.inferredCycleStart)
        fixture.update { $0.email = "a@example.com" }
        XCTAssertNil(try observationRefresh(coordinator, fixture: fixture).quotaPredictionContexts.first?.inferredCycleStart)
        fixture.update { $0.windows = [predictionWindows(now: base, seven: 25)[1]] }
        XCTAssertNotNil(try observationRefresh(coordinator, fixture: fixture).quotaPredictionContexts.first?.inferredCycleStart,
            "Missing five-hour window cannot invalidate healthy weekly basis")
    }

    private func observationStore() throws -> CodexResetObservationStore {
        let name = "BalanceBarTests.coordinator-observation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return CodexResetObservationStore(defaults: defaults)
    }

    private func observationCoordinator(
        _ fixture: ObservationFixture,
        store: CodexResetObservationStore,
        clock: TestClock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
    ) throws -> ProviderRefreshCoordinator {
        try setCurrentProvider("codex-replacement")
        DelayedBalanceURLProtocol.setHandler { fixture.reply($0) }
        return makeCoordinator(
            repository: repository,
            officialQuotaClient: OfficialQuotaClient(session: session, credentialReader: fixture, parser: fixture),
            codexResetObservationStore: store,
            queue: DispatchQueue(label: "test.observation.\(UUID().uuidString)"),
            actions: ProviderRefreshActions(
                currentProvider: { [repository] in repository?.loadCurrent(appType: $0.appType) },
                isActiveClient: { _ in true },
                render: { fixture.onRender?($0) },
                storeClientSnapshot: { _, _, _ in },
                quickSwitchSummaryChanged: { _ in fixture.onSummary?() }
            ),
            now: { clock.now }
        )
    }

    private func observationRefresh(_ coordinator: ProviderRefreshCoordinator, fixture: ObservationFixture, renders: Int = 1) throws -> Snapshot {
        let rendered = expectation(description: "official refresh publications")
        rendered.expectedFulfillmentCount = renders
        var snapshots: [Snapshot] = []
        fixture.onRender = { snapshots.append($0); rendered.fulfill() }
        coordinator.refreshStandardProvider(current: try XCTUnwrap(repository.loadCurrent(appType: "codex")), client: .codex, forceBalance: true, switched: false)
        wait(for: [rendered], timeout: 3)
        waitForCoordinator(coordinator)
        return try XCTUnwrap(snapshots.last)
    }

    private func makeCoordinator(
        repository: CCSwitchRepository,
        officialQuotaClient: OfficialQuotaClient,
        balanceAPIClient: BalanceAPIClient = BalanceAPIClient(),
        balanceProgressStore: ProviderBalanceProgressStore = ProviderBalanceProgressStore(),
        codexResetObservationStore: CodexResetObservationStore = CodexResetObservationStore(),
        queue: DispatchQueue = DispatchQueue(label: "test.provider-refresh.owner"),
        actions: ProviderRefreshActions,
        refreshPreferences: AppPreferences? = nil,
        claudeQuota: ClaudeQuotaPipeline? = nil,
        codexLocal: CodexLocalQuota? = nil,
        now: @escaping () -> Date = Date.init
    ) -> ProviderRefreshCoordinator {
        let coordinator = ProviderRefreshCoordinator(repository: repository, officialQuotaClient: officialQuotaClient,
            balanceAPIClient: balanceAPIClient, balanceProgressStore: balanceProgressStore,
            codexResetObservationStore: codexResetObservationStore, queue: queue, actions: actions,
            refreshPreferences: refreshPreferences, claudeQuota: claudeQuota, codexLocal: codexLocal, now: now)
        coordinators.append(coordinator)
        return coordinator
    }

    private func makeActions(
        _ quickSwitchSummaryChanged: @escaping (String) -> Void = { _ in }
    ) -> ProviderRefreshActions {
        ProviderRefreshActions(
            currentProvider: { [repository] client in
                repository?.loadCurrent(appType: client.appType)
            },
            isActiveClient: { _ in true },
            render: { _ in },
            storeClientSnapshot: { _, _, _ in },
            quickSwitchSummaryChanged: quickSwitchSummaryChanged,
        )
    }

    private func waitForCoordinator(_ coordinator: ProviderRefreshCoordinator) {
        let finished = DispatchSemaphore(value: 0)
        coordinator.performAsync { finished.signal() }
        waitForEvent(finished)
    }

    private func waitForEvent(_ event: DispatchSemaphore) {
        XCTAssertEqual(event.wait(timeout: .now() + 2), .success)
    }

    private func createFixtureDatabase() throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                CREATE TABLE providers (
                    id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    settings_config TEXT NOT NULL,
                    meta TEXT NOT NULL,
                    category TEXT,
                    website_url TEXT,
                    app_type TEXT NOT NULL,
                    is_current INTEGER NOT NULL,
                    sort_index INTEGER,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (id, app_type)
                );
                CREATE TABLE proxy_config (
                    app_type TEXT,
                    live_takeover_active INTEGER,
                    enabled INTEGER
                );
                CREATE TABLE proxy_live_backup (app_type TEXT);
                INSERT INTO proxy_config VALUES ('codex', 0, 1);
                INSERT INTO providers VALUES (
                    'codex-custom', 'Codex Custom',
                    '{"api_key":"fixture-key","base_url":"https://codex.provider.test"}',
                    '{"usage_script":{"enabled":true,"accessToken":"fixture-key","baseUrl":"https://codex.provider.test","code":"url: `{{baseUrl}}/usage`"}}',
                    'custom', 'https://codex.provider.test', 'codex', 1, 1, 1
                );
                INSERT INTO providers VALUES (
                    'codex-replacement', 'Codex Replacement', '{}', '{}',
                    'official', NULL, 'codex', 0, 2, 2
                );
                INSERT INTO providers VALUES (
                    'claude-custom', 'Claude Custom',
                    '{"api_key":"fixture-key","base_url":"https://claude.provider.test"}',
                    '{"usage_script":{"enabled":true,"accessToken":"fixture-key","baseUrl":"https://claude.provider.test","code":"url: `{{baseUrl}}/usage`"}}',
                    'custom', 'https://claude.provider.test', 'claude', 1, 1, 1
                );
                INSERT INTO providers VALUES (
                    'grok-custom', 'Grok Custom',
                    '{"api_key":"fixture-key","base_url":"https://grok.provider.test"}',
                    '{"usage_script":{"enabled":true,"accessToken":"fixture-key","baseUrl":"https://grok.provider.test","code":"url: `{{baseUrl}}/usage`"}}',
                    'custom', 'https://grok.provider.test', 'grokbuild', 1, 1, 1
                );
                """
            )
        }
    }

    private func setCurrentProvider(_ providerID: String) throws {
        try withDatabase { database in
            try execute(
                database,
                sql: "UPDATE providers SET is_current = CASE WHEN id = '\(providerID)' THEN 1 ELSE 0 END WHERE app_type = 'codex'"
            )
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let code = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard code == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw fixtureError("failed to open fixture database; sqlite code=\(code)")
        }
        sqlite3_busy_timeout(database, 1_000)
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer {
            if let errorMessage { sqlite3_free(errorMessage) }
        }
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            throw fixtureError("fixture SQL failed; sqlite code=\(code); extended=\(sqlite3_extended_errcode(database)); system_errno=\(sqlite3_system_errno(database)); error=\(message)")
        }
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "BalanceBar.ProviderRefreshCoordinatorTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}

private final class ActiveClientBox {
    var value: AssistantClient

    init(_ value: AssistantClient) {
        self.value = value
    }
}

private final class PublicationRecorder {
    private let lock = NSLock()
    private(set) var rendered: [Snapshot] = []
    private(set) var stored: [AssistantClient: (providerID: String, snapshot: Snapshot)] = [:]

    func recordRender(_ snapshot: Snapshot) {
        lock.lock()
        rendered.append(snapshot)
        lock.unlock()
    }

    func store(_ snapshot: Snapshot, client: AssistantClient, providerID: String) {
        lock.lock()
        stored[client] = (providerID, snapshot)
        lock.unlock()
    }
}

private struct FixtureCredentialReader: OfficialQuotaCredentialReading {
    let codexToken: String?
    var claudeToken: String? = nil

    func codexAccessToken() -> String? { codexToken }
    func codexAccountProfile() -> CodexAccountProfile? { nil }
    func claudeAccessToken() -> String? { claudeToken }
}

private final class PendingRender {
    private let lock = NSLock()
    private var pending: XCTestExpectation?
    func expect(_ expectation: XCTestExpectation) { lock.withLock { pending = expectation } }
    func fulfill() { lock.withLock { let current = pending; pending = nil; return current }?.fulfill() }
}

private struct ProfileCredentialReader: OfficialQuotaCredentialReading {
    let email: String
    func codexAccessToken() -> String? { "fixture-token" }
    func codexAccountProfile() -> CodexAccountProfile? { CodexAccountProfile(email: email, planType: "plus") }
    func claudeAccessToken() -> String? { nil }
}

private struct IncrementingOfficialQuotaParser: OfficialQuotaParsing {
    let counter: IncrementingCounter

    func parse(
        data: Data,
        client: AssistantClient
    ) throws -> OfficialQuotaResponseParser.Output {
        OfficialQuotaResponseParser.Output(
            windows: [
                OfficialQuotaWindow(
                    kind: .sevenDay,
                    remaining: Double(counter.next()),
                    label: "fixture",
                    daysText: "fixture-days",
                    reset: nil,
                    durationSeconds: 7 * 86_400
                )
            ]
        )
    }
}

private struct FixedOfficialQuotaParser: OfficialQuotaParsing {
    let windows: [OfficialQuotaWindow]
    let bankedReset: CodexBankedReset?
    let bankedResetNeedsCreditList: Bool

    init(
        windows: [OfficialQuotaWindow],
        bankedReset: CodexBankedReset? = nil,
        bankedResetNeedsCreditList: Bool = false
    ) {
        self.windows = windows
        self.bankedReset = bankedReset
        self.bankedResetNeedsCreditList = bankedResetNeedsCreditList
    }

    func parse(
        data: Data,
        client: AssistantClient
    ) throws -> OfficialQuotaResponseParser.Output {
        OfficialQuotaResponseParser.Output(
            windows: windows,
            bankedReset: bankedReset,
            bankedResetNeedsCreditList: bankedResetNeedsCreditList
        )
    }
}

private final class MutableOfficialQuotaWindows {
    private let lock = NSLock()
    private var value: [OfficialQuotaWindow]

    init(_ value: [OfficialQuotaWindow]) {
        self.value = value
    }

    func set(_ value: [OfficialQuotaWindow]) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> [OfficialQuotaWindow] {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct MutableOfficialQuotaParser: OfficialQuotaParsing {
    let windows: MutableOfficialQuotaWindows

    func parse(
        data: Data,
        client: AssistantClient
    ) throws -> OfficialQuotaResponseParser.Output {
        OfficialQuotaResponseParser.Output(windows: windows.get())
    }
}

private final class TestClock {
    private let lock = NSLock()
    private var value: Date

    init(date: Date) {
        value = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value.addTimeInterval(interval)
        lock.unlock()
    }
}

private final class RecordingBalanceNotificationClient: BalanceNotificationClient {
    var onResponse: (([AnyHashable: Any]) -> Void)?
    var status: BalanceNotificationPermissionState = .authorized
    private(set) var deliveries: [(title: String, body: String, userInfo: [AnyHashable: Any])] = []

    func authorizationStatus(completion: @escaping (BalanceNotificationPermissionState) -> Void) {
        completion(status)
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    func deliver(title: String, body: String, userInfo: [AnyHashable: Any]) {
        deliveries.append((title, body, userInfo))
    }

    func openSettings() {}
}

private final class AmountQueue {
    private let lock = NSLock()
    private var amounts: [String]

    init(_ amounts: [String]) {
        self.amounts = amounts
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !amounts.isEmpty else { return "0.00" }
        return amounts.removeFirst()
    }
}

private final class IncrementingCounter {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        value += 1
        let nextValue = value
        lock.unlock()
        return nextValue
    }
}

private final class ConcurrentDateSource {
    private let lock = NSLock()
    private let date: Date
    let firstRead = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private var readCount = 0
    private var activeReads = 0
    private var maximumActiveReads = 0

    init(date: Date) {
        self.date = date
    }

    var maximumConcurrentReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveReads
    }

    func read() -> Date {
        lock.lock()
        readCount += 1
        let shouldHold = readCount == 1
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        lock.unlock()

        if shouldHold {
            firstRead.signal()
            releaseGate.wait()
        }

        lock.lock()
        activeReads -= 1
        lock.unlock()
        return date
    }

    func releaseFirstRead() {
        releaseGate.signal()
    }
}

private final class FixtureSessionLifetime: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private let finished = DispatchSemaphore(value: 0)
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock(); invalidated = true; lock.unlock()
        finished.signal()
    }
    func waitUntilInvalidated() -> Bool {
        lock.lock(); let done = invalidated; lock.unlock()
        return done || finished.wait(timeout: .now() + 3) == .success
    }
}

private final class DelayedBalanceURLProtocol: URLProtocol {
    struct Reply {
        let data: Data
        let statusCode: Int
        let delayUntil: DispatchSemaphore?
        /// Fails the request at the transport level instead of answering.
        var transportError: URLError? = nil

        init(data: Data, statusCode: Int, delayUntil: DispatchSemaphore? = nil) {
            self.data = data
            self.statusCode = statusCode
            self.delayUntil = delayUntil
        }

        static func transportFailure(_ code: URLError.Code = .notConnectedToInternet) -> Reply {
            var reply = Reply(data: Data(), statusCode: 0)
            reply.transportError = URLError(code)
            return reply
        }
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var recordedRequestCount = 0
    private static let workers = DispatchGroup()
    private let deliveryLock = NSRecursiveLock()
    private var stopped = false

    static func waitUntilIdle() -> Bool { workers.wait(timeout: .now() + 3) == .success }

    static func reset() {
        lock.lock()
        handler = nil
        recordedRequestCount = 0
        lock.unlock()
    }

    static func setHandler(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequestCount
    }

    static func success(amount: String, unit: String = "USD") -> Reply {
        Reply(
            data: Data(#"{"balance":"\#(amount)","quota":{"unit":"\#(unit)"}}"#.utf8),
            statusCode: 200
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.workers.enter()
        Self.lock.lock()
        Self.recordedRequestCount += 1
        let handler = Self.handler
        Self.lock.unlock()

        let reply = handler?(request) ?? Self.success(amount: "0")

        if let gate = reply.delayUntil {
            DispatchQueue.global().async {
                defer { Self.workers.leave() }
                // A cancelled request must not leave a worker blocked on a
                // test gate that intentionally has no further successful reply.
                while gate.wait(timeout: .now() + 0.01) == .timedOut {
                    self.deliveryLock.lock(); let cancelled = self.stopped; self.deliveryLock.unlock()
                    if cancelled { return }
                }
                self.deliver(reply)
            }
        } else {
            defer { Self.workers.leave() }
            deliver(reply)
        }
    }

    private func deliver(_ reply: Reply) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !stopped else { return }
        if let error = reply.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        deliveryLock.lock(); stopped = true; deliveryLock.unlock()
    }
}


/// Uses a real account and asynchronous URLSession transport, with no auth-file
/// or network dependencies. Locking permits account changes during a response.
private final class ObservationFixture: OfficialQuotaCredentialReading, OfficialQuotaParsing {
    struct State {
        var email = "a@example.com"
        var windows = ObservationFixture.windows(70, 80, cycle: 1)
        var forecast = ObservationFixture.forecast(episode: "first")
        var quotaStatus = 200
        var forecastStatus = 200
        var needsCreditList = false
        var hasBankedReset = true
        var quotaRequests = 0
        var quotaGate: (DispatchSemaphore, DispatchSemaphore)?
        var creditGate: (DispatchSemaphore, DispatchSemaphore)?
        var authorization: String?
        var forecastRequests = 0
    }
    private let lock = NSLock()
    private var state = State()
    var onRender: ((Snapshot) -> Void)?
    var onSummary: (() -> Void)?
    func update(_ change: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; change(&state) }
    private func read() -> State { lock.lock(); defer { lock.unlock() }; return state }
    var lastAuthorization: String? { read().authorization }
    var forecastRequestCount: Int { read().forecastRequests }
    var quotaRequestCount: Int { read().quotaRequests }
    func codexAccessToken() -> String? { codexRequestCredentials().accessToken }
    func codexAccountProfile() -> CodexAccountProfile? { CodexAccountProfile(email: read().email, planType: nil) }
    func claudeAccessToken() -> String? { nil }
    func codexRequestCredentials() -> CodexRequestCredentials {
        let email = read().email
        return CodexRequestCredentials(accessToken: "token-" + email, accountKey: email)
    }
    func parse(data: Data, client: AssistantClient) throws -> OfficialQuotaResponseParser.Output {
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let values = object["windows"] as! [[String: Any]]
        let windows = values.map {
            OfficialQuotaWindow(kind: OfficialQuotaWindow.Kind(rawValue: $0["kind"] as! Int)!, remaining: $0["remaining"] as! Double, label: $0["label"] as! String, daysText: $0["label"] as! String, reset: nil, durationSeconds: $0["duration"] as? Double, resetAt: ($0["resetAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        return OfficialQuotaResponseParser.Output(windows: windows, bankedReset: (object["hasBankedReset"] as! Bool) ? CodexBankedReset(cards: []) : nil, bankedResetNeedsCreditList: object["needsCreditList"] as! Bool)
    }
    func reply(_ request: URLRequest) -> DelayedBalanceURLProtocol.Reply {
        let state = read()
        if request.url?.path == "/api/forecast" {
            update { $0.forecastRequests += 1 }
            return .init(data: state.forecast, statusCode: state.forecastStatus)
        }
        if request.url?.path.contains("credits") == true {
            if let gate = state.creditGate { gate.0.signal() }
            return .init(data: Data("{}".utf8), statusCode: 503, delayUntil: state.creditGate?.1)
        }
        update { $0.authorization = request.value(forHTTPHeaderField: "Authorization"); $0.quotaRequests += 1 }
        if let gate = state.quotaGate { gate.0.signal() }
        let windows: [[String: Any]] = state.windows.map {
            var value: [String: Any] = ["kind": $0.kind.rawValue, "remaining": $0.remaining, "label": $0.label]
            value["duration"] = $0.durationSeconds
            value["resetAt"] = $0.resetAt?.timeIntervalSince1970
            return value
        }
        let data = try! JSONSerialization.data(withJSONObject: ["windows": windows, "needsCreditList": state.needsCreditList, "hasBankedReset": state.hasBankedReset])
        return .init(data: data, statusCode: state.quotaStatus, delayUntil: state.quotaGate?.1)
    }
    static func windows(_ five: Double, _ seven: Double, cycle: Int) -> [OfficialQuotaWindow] {
        [.init(kind: .fiveHour, remaining: five, label: "5h", daysText: "5h", reset: nil, durationSeconds: 18_000),
         .init(kind: .sevenDay, remaining: seven, label: "7d", daysText: "7d", reset: nil, durationSeconds: 604_800, resetAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(cycle) * 604_800))]
    }
    static func forecast(episode: String?, signal: Bool = true, publishedAt: Date? = nil) -> Data {
        var official: [String: Any] = episode.map { ["tweet_id": $0, "score": ["value": 80]] } ?? ["score": ["value": 80]]
        if let publishedAt { official["at"] = ISO8601DateFormatter().string(from: publishedAt) }
        return try! JSONSerialization.data(withJSONObject: ["official_signal": signal ? official as Any : NSNull(), "probabilities": ["rounded_24h": 24, "rounded_48h": 42]])
    }
}

extension ProviderRefreshCoordinatorTests {
    private func aggregationFixture(members: [String] = [], route: String = "codex-custom") throws -> CCSwitchAggregationRepository {
        let url = temporaryDirectoryURL.appendingPathComponent("live-state.json")
        try JSONSerialization.data(withJSONObject: ["apps": ["codex": ["mode": "proxy", "attached": true,
            "proxy_route": route, "stack": ["enabled": true, "members": members]]]]).write(to: url, options: .atomic)
        return CCSwitchAggregationRepository(repository: repository, stateURL: url, isRunning: { true })
    }

    private func addAggregationMembers(_ count: Int) throws {
        try withDatabase { db in
            for i in 0..<count {
                try execute(db, sql: "INSERT INTO providers SELECT 'member-\(i)', 'Codex Custom', settings_config, meta, category, website_url, app_type, 0, 10, 10 FROM providers WHERE id='codex-custom'")
            }
        }
    }

    private func aggregationCoordinator(official: OfficialQuotaClient? = nil,
                                        _ changed: @escaping ([AggregatedProviderDisplay], Bool) -> Void) -> ProviderRefreshCoordinator {
        var actions = makeActions()
        actions.aggregationChanged = changed
        let defaults = UserDefaults(suiteName: temporaryDirectoryURL.lastPathComponent + ".Aggregation")!
        return makeCoordinator(repository: repository,
            officialQuotaClient: official ?? OfficialQuotaClient(session: session, credentialReader: FixtureCredentialReader(codexToken: "fixture-token")),
            balanceAPIClient: BalanceAPIClient(session: session),
            balanceProgressStore: ProviderBalanceProgressStore(defaults: defaults),
            codexResetObservationStore: CodexResetObservationStore(defaults: defaults),
            actions: actions)
    }

    func testConfiguredAggregationKeepsOfficialAndAPICadencesIndependent() throws {
        let reader = try aggregationFixture(members: ["codex-custom"], route: "codex-replacement")
        let suite = "AggregationCadence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.officialUsageRefreshInterval = 180
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let counter = IncrementingCounter()
        DelayedBalanceURLProtocol.setHandler { request in
            if request.url?.host == "codex.provider.test" {
                return DelayedBalanceURLProtocol.success(amount: String(counter.next()))
            }
            return .init(data: Data("{}".utf8), statusCode: 200)
        }
        let first = expectation(description: "both providers initially fresh")
        let api = expectation(description: "API independently refreshes after three seconds")
        var initialDelivered = false
        var apiDelivered = false
        var actions = makeActions()
        actions.aggregationChanged = { displays, _ in
            if displays.filter({ $0.status == .fresh }).count == 2, !initialDelivered {
                initialDelivered = true
                first.fulfill()
            }
            if displays.contains(where: { $0.identity.providerID == "codex-custom" && $0.snapshot.amount == 2 }), !apiDelivered {
                apiDelivered = true
                api.fulfill()
            }
        }
        let window = OfficialQuotaWindow(kind: .fiveHour, remaining: 80, label: "5h",
            daysText: "5 hours", reset: nil, durationSeconds: 18_000)
        let coordinator = makeCoordinator(repository: repository,
            officialQuotaClient: OfficialQuotaClient(session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture"),
                parser: FixedOfficialQuotaParser(windows: [window])),
            balanceAPIClient: BalanceAPIClient(session: session), actions: actions,
            refreshPreferences: preferences, now: { clock.now })
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [first], timeout: 3)
        clock.advance(by: 3)
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true, forceAPIBalance: true) }
        wait(for: [api], timeout: 3)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3, "official quota must not follow API's three-second cadence")
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true, forceAPIBalance: false) }
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3, "API trailing window can end independently")
    }

    func testAggregationBoundsConcurrentRequestsAndCancelsRemovedMembers() throws {
        try addAggregationMembers(6)
        let reader = try aggregationFixture(members: (0..<6).map { "member-\($0)" })
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<7 { gate.signal() } }
        let started = expectation(description: "two active transports")
        started.expectedFulfillmentCount = 2
        DelayedBalanceURLProtocol.setHandler { _ in
            started.fulfill()
            return .init(data: Data(#"{"balance":"4.73","quota":{"unit":"USD"}}"#.utf8), statusCode: 200, delayUntil: gate)
        }
        let coordinator = aggregationCoordinator { _, _ in }
        coordinator.performAsync { XCTAssertTrue(coordinator.refreshAggregation(reader: reader, force: true)) }
        wait(for: [started], timeout: 3)
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
        coordinator.stopAggregation()
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
    }

    func testAggregationNewMemberBypassesOtherProvidersTTLAndManualRefreshesAll() throws {
        try addAggregationMembers(1)
        let reader = try aggregationFixture()
        let first = expectation(description: "first provider fresh")
        let added = expectation(description: "new member fresh")
        let refreshed = expectation(description: "manual all fresh")
        var phase = 0
        var firstDone = false
        var addedDone = false
        var refreshedDone = false
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "4.73") }
        let coordinator = aggregationCoordinator { displays, _ in
            let fresh = displays.filter { $0.status == .fresh }
            for display in fresh {
                XCTAssertEqual(display.snapshot.progressPercentage, 100)
                XCTAssertEqual(display.snapshot.balanceProgressContext?.baselineCents, 473)
                XCTAssertNotNil(display.snapshot.balanceProgressContext?.baselineObservedAt)
                XCTAssertNil(display.snapshot.balanceRecharge)
            }
            if phase == 0, fresh.count == 1, !firstDone { firstDone = true; first.fulfill() }
            if phase == 1, fresh.count == 2, !addedDone { addedDone = true; added.fulfill() }
            if phase == 2, fresh.count == 2, DelayedBalanceURLProtocol.requestCount == 4, !refreshedDone {
                refreshedDone = true; refreshed.fulfill()
            }
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [first], timeout: 3)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        _ = try aggregationFixture(members: ["member-0"])
        coordinator.performAsync { phase = 1; _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [added], timeout: 3)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
        coordinator.performAsync { phase = 2; _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [refreshed], timeout: 3)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 4)
    }

    func testAggregationConfigChangeRejectsInFlightSameIDAndNeverReusesWrongBalance() throws {
        let reader = try aggregationFixture()
        let oldStarted = expectation(description: "old configuration in flight")
        let newFresh = expectation(description: "new configuration fresh")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        DelayedBalanceURLProtocol.setHandler { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" {
                oldStarted.fulfill()
                return .init(data: Data(#"{"balance":"99.00"}"#.utf8), statusCode: 200, delayUntil: gate)
            }
            return DelayedBalanceURLProtocol.success(amount: "2.67", unit: "CNY")
        }
        var done = false
        let coordinator = aggregationCoordinator { displays, _ in
            guard let display = displays.first, display.status == .fresh else { return }
            XCTAssertEqual(display.snapshot.amount, 2.67)
            XCTAssertEqual(display.snapshot.unit, "CNY")
            if !done { done = true; newFresh.fulfill() }
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [oldStarted], timeout: 3)
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET meta=replace(meta, 'fixture-key', 'new-fixture-key') WHERE id='codex-custom'")
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [newFresh], timeout: 3)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
    }

    func testAggregationLocalFailureKeepsOnlyItsOwnTrustedSnapshotAndRecovers() throws {
        try addAggregationMembers(1)
        let reader = try aggregationFixture(members: ["member-0"])
        let fresh = expectation(description: "both providers fresh")
        let stale = expectation(description: "cached failure marked stale")
        let restored = expectation(description: "network recovery")
        var phase = 0
        var freshDone = false
        var staleDone = false
        var restoredDone = false
        DelayedBalanceURLProtocol.setHandler { _ in
            DelayedBalanceURLProtocol.success(amount: "4.73")
        }
        let coordinator = aggregationCoordinator { displays, _ in
            if phase == 0, displays.count == 2, displays.allSatisfy({ $0.status == .fresh }), !freshDone {
                freshDone = true; fresh.fulfill()
            }
            if phase == 1, displays.count == 2, displays.allSatisfy({ $0.status == .stale }), !staleDone {
                XCTAssertTrue(displays.allSatisfy { $0.snapshot.amount == 4.73 && $0.fetchedAt != nil && $0.reason != nil })
                staleDone = true; stale.fulfill()
            }
            if phase == 2, displays.count == 2, displays.allSatisfy({ $0.status == .fresh }), !restoredDone {
                restoredDone = true; restored.fulfill()
            }
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [fresh], timeout: 3)
        DelayedBalanceURLProtocol.setHandler { _ in .init(data: Data(), statusCode: 429) }
        coordinator.performAsync { phase = 1; _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [stale], timeout: 3)
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "4.73") }
        coordinator.performAsync { phase = 2; _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [restored], timeout: 3)
    }
}

extension ProviderRefreshCoordinatorTests {
    func testAggregationOfficialDefaultKeepsFullQuotaResetCardsAndThirdPartyCurrency() throws {
        let reader = try aggregationFixture(members: ["codex-custom"], route: "codex-replacement")
        let windows = ObservationFixture.windows(80, 45, cycle: 1)
        let banked = CodexBankedReset(cards: [CodexBankedResetCard(id: "fixture-card", resetType: "codex_rate_limits",
            titleText: "Fixture reset", expiresAt: Date().addingTimeInterval(3600), expiresText: nil)])
        let ready = expectation(description: "full official and independent balance")
        var done = false
        DelayedBalanceURLProtocol.setHandler { request in
            if request.url?.host == "codex-reset.com" { return .init(data: Data(#"{"probabilities":{"rounded_24h":24,"rounded_48h":42}}"#.utf8), statusCode: 200) }
            return DelayedBalanceURLProtocol.success(amount: "2.67", unit: "CNY")
        }
        let official = OfficialQuotaClient(session: session, credentialReader: FixtureCredentialReader(codexToken: "fixture-token"),
            parser: FixedOfficialQuotaParser(windows: windows, bankedReset: banked))
        let coordinator = aggregationCoordinator(official: official) { displays, _ in
            guard displays.count == 2, displays.allSatisfy({ $0.status == .fresh }), !done else { return }
            done = true
            XCTAssertEqual(displays.first(where: { $0.entry.role == .default })!.entry.role, .default)
            XCTAssertEqual(displays.first(where: { $0.entry.role == .default })!.snapshot.kind, .official)
            XCTAssertEqual(displays.first(where: { $0.entry.role == .default })!.snapshot.officialQuotaWindows.map(\.remaining), [80, 45])
            XCTAssertEqual(displays.first(where: { $0.entry.role == .default })!.snapshot.bankedReset?.cards.first?.id, "fixture-card")
            XCTAssertEqual(displays.first(where: { $0.entry.role == .default })!.snapshot.resetForecast.probability24h, .percent(24))
            XCTAssertEqual(displays.first(where: { $0.entry.role == .member })!.snapshot.kind, .balance)
            XCTAssertEqual(displays.first(where: { $0.entry.role == .member })!.snapshot.unit, "CNY")
            XCTAssertEqual(displays.first(where: { $0.entry.role == .member })!.snapshot.amount, 2.67)
            XCTAssertNil(displays.first(where: { $0.entry.role == .member })!.account)
            ready.fulfill()
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [ready], timeout: 3)
    }

    func testAggregationAccountChangeDiscardsOldOfficialRequestAndCache() throws {
        let reader = try aggregationFixture(route: "codex-replacement")
        let fixture = ObservationFixture()
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        fixture.update { $0.quotaGate = (started, gate) }
        DelayedBalanceURLProtocol.setHandler { fixture.reply($0) }
        let ready = expectation(description: "new account quota")
        var done = false
        let official = OfficialQuotaClient(session: session, credentialReader: fixture, parser: fixture)
        let coordinator = aggregationCoordinator(official: official) { displays, _ in
            guard let display = displays.first, display.status == .fresh, !done else { return }
            done = true
            XCTAssertEqual(display.account?.state, .available("b@example.com"))
            XCTAssertEqual(display.snapshot.officialQuotaWindows.first?.remaining, 10)
            ready.fulfill()
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        waitForEvent(started)
        fixture.update { $0.email = "b@example.com"; $0.windows = ObservationFixture.windows(10, 20, cycle: 1); $0.quotaGate = nil }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [ready], timeout: 3)
        XCTAssertEqual(fixture.quotaRequestCount, 2)
    }
}

extension ProviderRefreshCoordinatorTests {
    func testAggregationUnchangedSyncDoesNotRepublishPresentation() throws {
        let reader = try aggregationFixture()
        let ready = expectation(description: "fresh balance")
        var done = false
        var publications = 0
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "4.73") }
        let coordinator = aggregationCoordinator { displays, _ in
            publications += 1
            if displays.first?.status == .fresh, !done { done = true; ready.fulfill() }
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [ready], timeout: 3)
        waitForCoordinator(coordinator)
        let previous = publications
        coordinator.performAsync { for _ in 0..<20 { _ = coordinator.refreshAggregation(reader: reader, force: false) } }
        waitForCoordinator(coordinator)
        XCTAssertEqual(publications, previous)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
    }

    func testAggregationStoredTokenQuotaActuallyStopsWhenOfficialDefaultIsRemoved() throws {
        try addAggregationMembers(4)
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET settings_config='{\"auth\":{\"tokens\":{\"access_token\":\"fixture-stored-token\"}}}' WHERE id='codex-replacement'")
        }
        let reader = try aggregationFixture(members: (0..<4).map { "member-\($0)" }, route: "codex-replacement")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoppedAggregationQuotaProtocol.self]
        let stoppedSession = URLSession(configuration: configuration)
        defer { stoppedSession.invalidateAndCancel(); StoppedAggregationQuotaProtocol.reset() }
        StoppedAggregationQuotaProtocol.reset()
        let started = expectation(description: "stored token transport started")
        let stopped = expectation(description: "stored token transport stopLoading observed")
        StoppedAggregationQuotaProtocol.onStart = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-stored-token")
            started.fulfill()
        }
        StoppedAggregationQuotaProtocol.onStop = { stopped.fulfill() }
        let official = OfficialQuotaClient(session: stoppedSession, credentialReader: FixtureCredentialReader(codexToken: "different-local-token"))
        var actions = makeActions()
        let defaults = UserDefaults(suiteName: temporaryDirectoryURL.lastPathComponent + ".Aggregation")!
        var sawOldOfficialData = false
        var newDefaultPublished = false
        let newDefaultReady = expectation(description: "replacement default publishes its own fresh data")
        actions.aggregationChanged = { displays, _ in
            if displays.contains(where: { $0.identity.providerID == "codex-replacement" && $0.status == .fresh }) { sawOldOfficialData = true }
            if let current = displays.first(where: { $0.entry.role == .default }), current.identity.providerID == "codex-custom", current.status == .fresh, !newDefaultPublished {
                newDefaultPublished = true
                newDefaultReady.fulfill()
            }
        }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            balanceAPIClient: BalanceAPIClient(session: stoppedSession), balanceProgressStore: ProviderBalanceProgressStore(defaults: defaults),
            codexResetObservationStore: CodexResetObservationStore(defaults: defaults), actions: actions)
        defer { coordinator.stop() }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [started], timeout: 3)
        _ = try aggregationFixture(members: (0..<4).map { "member-\($0)" }, route: "codex-custom")
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [stopped, newDefaultReady], timeout: 3)
        waitForCoordinator(coordinator)
        let credentials = CodexRequestCredentials(accessToken: "fixture-stored-token", accountKey: nil)
        XCTAssertFalse(official.isRequestInFlight(client: .codex, providerID: "codex-replacement",
            credentialSource: .storedAccessToken, requestCredentials: credentials, storedAccessToken: "fixture-stored-token"))
        XCTAssertFalse(sawOldOfficialData)
        XCTAssertLessThanOrEqual(StoppedAggregationQuotaProtocol.maximumActive, 2)
        coordinator.stopAggregation()
        waitForCoordinator(coordinator)
    }
}

private final class StoppedAggregationQuotaProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var active = 0
    private static var maximum = 0
    static var onStart: ((URLRequest) -> Void)?
    static var onStop: (() -> Void)?
    private var counted = false
    private var isQuota = false
    static var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    static func reset() { lock.lock(); defer { lock.unlock() }; active = 0; maximum = 0; onStart = nil; onStop = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        isQuota = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-stored-token"
        Self.lock.lock(); counted = true; Self.active += 1; Self.maximum = max(Self.maximum, Self.active); Self.lock.unlock()
        if isQuota { Self.onStart?(request); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"balance":"4.73","quota":{"unit":"USD"}}"#.utf8))
        finishActive()
        client?.urlProtocolDidFinishLoading(self)
    }
    private func finishActive() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if counted { counted = false; Self.active -= 1 }
    }
    override func stopLoading() {
        finishActive()
        if isQuota { Self.onStop?() }
    }
}

extension ProviderRefreshCoordinatorTests {
    func testConfigurationEventsRespectTTLButSourceChangeAndManualRefreshQueryImmediately() throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let changed = DispatchSemaphore(value: 0)
        let counter = IncrementingCounter()
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "\(counter.next()).00") }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session), actions: makeActions { _ in changed.signal() }, now: { clock.now })
        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForEvent(changed)
        for _ in 0..<20 { coordinator.refreshQuickSwitchSummaries(force: false, for: .codex, configurationChanged: true) }
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET name='Codex renamed' WHERE id='codex-custom'")
        }
        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex, configurationChanged: true)
        waitForEvent(changed)
        waitForEvent(changed)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex)
        waitForEvent(changed)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)
    }

    func testStandardProviderConfigurationRevisionBypassesTTLWithoutForcingUnchangedSources() throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let initial = expectation(description: "initial source rendered")
        let replaced = expectation(description: "changed source rendered")
        var renderCount = 0
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "4.73") }
        var actions = makeActions()
        actions = ProviderRefreshActions(currentProvider: actions.currentProvider, isActiveClient: actions.isActiveClient,
            render: { _ in
                renderCount += 1
                if renderCount == 1 { initial.fulfill() } else { replaced.fulfill() }
            }, storeClientSnapshot: actions.storeClientSnapshot, quickSwitchSummaryChanged: actions.quickSwitchSummaryChanged)
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session), actions: actions, now: { clock.now })
        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: false, switched: false)
        wait(for: [initial], timeout: 2)
        for _ in 0..<20 { coordinator.refreshStandardProvider(current: current, client: .codex, forceBalance: false, switched: false) }
        waitForCoordinator(coordinator)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        try withDatabase { db in try execute(db, sql: "UPDATE providers SET name='Renamed' WHERE id='codex-custom'") }
        let replacement = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        XCTAssertNotEqual(replacement.configurationRevision, current.configurationRevision)
        coordinator.refreshStandardProvider(current: replacement, client: .codex, forceBalance: false, switched: false)
        wait(for: [replaced], timeout: 2)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
    }
}

extension ProviderRefreshCoordinatorTests {
    func testStandardProviderIgnoresLateResponseAfterAPIKeyChange() throws {
        let oldStarted = expectation(description: "old key request started")
        let rendered = expectation(description: "new key balance rendered")
        let releaseOld = DispatchSemaphore(value: 0)
        defer { releaseOld.signal() }
        DelayedBalanceURLProtocol.setHandler { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" {
                oldStarted.fulfill()
                return .init(data: Data(#"{"balance":"3","quota":{"unit":"USD"}}"#.utf8), statusCode: 200, delayUntil: releaseOld)
            }
            return DelayedBalanceURLProtocol.success(amount: "20")
        }
        let lock = NSLock()
        var snapshots: [Snapshot] = []
        var stored: [(String, Snapshot)] = []
        var notifications: [Snapshot] = []
        var actions = makeActions()
        actions = ProviderRefreshActions(
            currentProvider: actions.currentProvider,
            isActiveClient: actions.isActiveClient,
            render: { snapshot in
                lock.lock(); snapshots.append(snapshot); lock.unlock(); rendered.fulfill()
            },
            storeClientSnapshot: { _, providerID, snapshot in
                lock.lock(); stored.append((providerID, snapshot)); lock.unlock()
            },
            quickSwitchSummaryChanged: { _ in },
            notificationSnapshot: { _, _, snapshot in
                lock.lock(); notifications.append(snapshot); lock.unlock()
            }
        )
        let coordinator = makeCoordinator(
            repository: repository, officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session), actions: actions
        )
        let original = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        coordinator.refreshStandardProvider(current: original, client: .codex, forceBalance: true, switched: false)
        wait(for: [oldStarted], timeout: 2)
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET meta=replace(meta, 'fixture-key', 'new-key'), settings_config=replace(settings_config, 'fixture-key', 'new-key') WHERE id='codex-custom'")
        }
        let replacement = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        XCTAssertNotEqual(replacement.configurationRevision, original.configurationRevision)
        coordinator.refreshStandardProvider(current: replacement, client: .codex, forceBalance: true, switched: false)
        wait(for: [rendered], timeout: 2)
        releaseOld.signal()
        waitForCoordinator(coordinator)
        lock.lock(); let published = snapshots; let cached = stored; let notified = notifications; lock.unlock()
        XCTAssertEqual(published.map(\.amount), [20])
        XCTAssertEqual(cached.map(\.1.amount), [20])
        XCTAssertEqual(notified.map(\.amount), [20])
        XCTAssertEqual(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .defaultValue, client: .codex)["codex-custom"], "$20.00")
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
    }

    func testQuickSwitchSummaryIsClearedWhenConfigurationRevisionChangesAndRefreshFails() throws {
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "3") }
        let changed = DispatchSemaphore(value: 0)
        let summaryCleared = expectation(description: "summary cleared after revision change")
        var summaryNotifications = 0
        let coordinator = makeCoordinator(
            repository: repository, officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session),
            actions: makeActions { _ in
                changed.signal()
                summaryNotifications += 1
                if summaryNotifications == 2 { summaryCleared.fulfill() }
            }
        )
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: ["codex-custom"])
        waitForEvent(changed)
        XCTAssertEqual(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .defaultValue, client: .codex)["codex-custom"], "$3.00")
        try withDatabase { db in
            try execute(db, sql: """
                UPDATE providers SET settings_config='{"api_key":"new-key","base_url":"https://codex.provider.test"}',
                    meta='{"usage_script":{"enabled":true,"accessToken":"new-key","baseUrl":"https://codex.provider.test","code":"url: `{{baseUrl}}/usage`"}}'
                WHERE id='codex-custom'
                """)
        }
        DelayedBalanceURLProtocol.setHandler { _ in
            .init(data: Data(), statusCode: 401)
        }
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: ["codex-custom"], configurationChanged: true)
        wait(for: [summaryCleared], timeout: 2)
        XCTAssertNil(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .defaultValue, client: .codex)["codex-custom"])
    }
}


extension ProviderRefreshCoordinatorTests {
    func testSharedQueryRejectedLateResponseDoesNotPublishOrNotify() throws {
        try withDatabase { db in
            try execute(db, sql: """
                INSERT INTO providers SELECT 'claude-wallet-peer', 'Peer', settings_config, meta,
                    category, website_url, app_type, 0, 2, 2 FROM providers WHERE id='claude-custom'
                """)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: temporaryDirectoryURL.lastPathComponent + ".Wallet"))
        defer { defaults.removePersistentDomain(forName: temporaryDirectoryURL.lastPathComponent + ".Wallet") }
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        defer { releaseOld.signal() }
        let counter = IncrementingCounter()
        DelayedBalanceURLProtocol.setHandler { _ in
            switch counter.next() {
            case 1: return DelayedBalanceURLProtocol.success(amount: "3")
            case 2:
                oldStarted.signal()
                return .init(data: Data(#"{"balance":20,"quota":{"unit":"USD"}}"#.utf8), statusCode: 200, delayUntil: releaseOld)
            default: return DelayedBalanceURLProtocol.success(amount: "13")
            }
        }
        let published = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var values: [(String, Snapshot)] = []
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = makeCoordinator(repository: repository,
            officialQuotaClient: OfficialQuotaClient(), balanceAPIClient: BalanceAPIClient(session: session),
            balanceProgressStore: ProviderBalanceProgressStore(defaults: defaults),
            queue: DispatchQueue(label: "test.shared-wallet-observations"),
            actions: .init(currentProvider: { _ in nil }, isActiveClient: { _ in false }, render: { _ in },
                storeClientSnapshot: { _, _, _ in }, quickSwitchSummaryChanged: { _ in },
                notificationSnapshot: { _, id, snapshot in
                    lock.lock(); values.append((id, snapshot)); lock.unlock(); published.signal()
                }), now: { clock.now })
        coordinator.refreshQuickSwitchSummaries(force: true, for: .claude, providerIDs: ["claude-custom"])
        waitForEvent(published)
        coordinator.refreshQuickSwitchSummaries(force: true, for: .claude, providerIDs: ["claude-custom"])
        waitForEvent(oldStarted)
        clock.advance(by: 60)
        coordinator.refreshQuickSwitchSummaries(force: true, for: .claude, providerIDs: ["claude-wallet-peer"])
        waitForEvent(published)
        releaseOld.signal()
        waitForCoordinator(coordinator)
        XCTAssertEqual(published.wait(timeout: .now() + 0.2), .timedOut)
        lock.lock(); let snapshots = values; lock.unlock()
        XCTAssertEqual(snapshots.map { $0.0 }, ["claude-custom", "claude-wallet-peer"])
        XCTAssertEqual(snapshots.map { $0.1.amount }, [3, 13])
        XCTAssertNil(snapshots[0].1.balanceRecharge)
        XCTAssertNotNil(snapshots[0].1.balanceProgressContext)
        XCTAssertNotNil(snapshots[0].1.progressPercentage)
        XCTAssertEqual(snapshots[1].1.balanceRecharge?.amountCents, 1000)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)
    }
}


extension ProviderRefreshCoordinatorTests {
    func testCodexSameNameDifferentKeysHaveIndependentHistoryAndNotifications() throws {
        try withDatabase { db in
            try execute(db, sql: """
                INSERT INTO providers SELECT 'codex-wallet-peer', 'Codex Custom', settings_config, replace(meta, 'fixture-key', 'peer-key'),
                    category, website_url, app_type, 0, 2, 2 FROM providers WHERE id='codex-custom'
                """)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: temporaryDirectoryURL.lastPathComponent + ".Wallet"))
        defer { defaults.removePersistentDomain(forName: temporaryDirectoryURL.lastPathComponent + ".Wallet") }
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        defer { releaseOld.signal() }
        let counter = IncrementingCounter()
        DelayedBalanceURLProtocol.setHandler { _ in
            switch counter.next() {
            case 1: return DelayedBalanceURLProtocol.success(amount: "3")
            case 2:
                oldStarted.signal()
                return .init(data: Data(#"{"balance":20,"quota":{"unit":"USD"}}"#.utf8), statusCode: 200, delayUntil: releaseOld)
            default: return DelayedBalanceURLProtocol.success(amount: "13")
            }
        }
        let published = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var values: [(String, Snapshot)] = []
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = makeCoordinator(repository: repository,
            officialQuotaClient: OfficialQuotaClient(), balanceAPIClient: BalanceAPIClient(session: session),
            balanceProgressStore: ProviderBalanceProgressStore(defaults: defaults),
            queue: DispatchQueue(label: "test.shared-wallet-observations"),
            actions: .init(currentProvider: { _ in nil }, isActiveClient: { _ in false }, render: { _ in },
                storeClientSnapshot: { _, _, _ in }, quickSwitchSummaryChanged: { _ in },
                notificationSnapshot: { _, id, snapshot in
                    lock.lock(); values.append((id, snapshot)); lock.unlock(); published.signal()
                }), now: { clock.now })
        coordinator.refreshStandardProvider(current: try XCTUnwrap(repository.loadCurrent(appType: "codex")),
            client: .codex, forceBalance: true, switched: false)
        waitForEvent(published)
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: ["codex-custom"])
        waitForEvent(oldStarted)
        clock.advance(by: 60)
        let reader = try aggregationFixture(route: "codex-wallet-peer")
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true) }
        waitForEvent(published)
        releaseOld.signal()
        waitForEvent(published)
        lock.lock(); let snapshots = values; lock.unlock()
        XCTAssertEqual(snapshots.map { $0.0 }, ["codex-custom", "codex-wallet-peer", "codex-custom"])
        XCTAssertEqual(snapshots.map { $0.1.amount }, [3, 13, 20])
        XCTAssertNil(snapshots[0].1.balanceRecharge)
        XCTAssertNotNil(snapshots[0].1.balanceProgressContext)
        XCTAssertNotNil(snapshots[0].1.progressPercentage)
        XCTAssertNil(snapshots[1].1.balanceRecharge)
        XCTAssertEqual(snapshots[2].1.balanceRecharge?.amountCents, 1700)
        XCTAssertEqual(snapshots[2].1.date, clock.now)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3)
    }
}

extension ProviderRefreshCoordinatorTests {
    func testAggregationSortRepublishesTagsWithinTTLWithoutStartingRequests() throws {
        try withDatabase { db in
            try execute(db, sql: "ALTER TABLE providers ADD COLUMN notes TEXT")
            try execute(db, sql: "UPDATE providers SET notes='Grok' WHERE id='codex-custom'")
            try execute(db, sql: """
                INSERT INTO providers SELECT 'peer', name, settings_config, meta, category, website_url,
                    app_type, 0, 3, 3, 'GPT' FROM providers WHERE id='codex-custom'
                """)
        }
        let reader = try aggregationFixture(members: ["peer"])
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "3.73") }
        let first = expectation(description: "initial fresh notes")
        let reordered = expectation(description: "sort-only publication")
        var initialPublished = false
        var reorderPublished = false
        let coordinator = aggregationCoordinator { displays, _ in
            guard displays.count == 2, displays.allSatisfy({ $0.status == .fresh }) else { return }
            let notes = AggregationWalletPresentation.cards(displays).first?.groupedNotes
            if notes == ["Grok", "GPT"], !initialPublished { initialPublished = true; first.fulfill() }
            if notes == ["GPT", "Grok"], !reorderPublished { reorderPublished = true; reordered.fulfill() }
        }
        defer { coordinator.stopAggregation() }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [first], timeout: 3)
        let requests = DelayedBalanceURLProtocol.requestCount
        XCTAssertEqual(requests, 2)
        try withDatabase { db in try execute(db, sql: "UPDATE providers SET sort_index=0 WHERE id='peer'") }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: false) }
        wait(for: [reordered], timeout: 3)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, requests)
    }
}

extension ProviderRefreshCoordinatorTests {
    func testTransientAggregationReadFailuresRetainTrustedMembershipAndBlockSwitch() throws {
        try addAggregationMembers(1)
        let reader = try aggregationFixture(members: ["member-0"])
        let validState = try Data(contentsOf: reader.stateURL)
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "3") }
        let ready = expectation(description: "trusted members")
        var latest: [AggregatedProviderDisplay] = []
        var blocked = false
        var announced = false
        let coordinator = aggregationCoordinator { displays, protection in
            latest = displays; blocked = protection
            if displays.count == 2 && displays.allSatisfy({ $0.status == .fresh }) && !announced {
                announced = true; ready.fulfill()
            }
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [ready], timeout: 3)
        func verifyUntrusted() {
            let checked = expectation(description: "trusted cache retained")
            coordinator.performAsync {
                XCTAssertTrue(coordinator.refreshAggregation(reader: reader, force: false))
                XCTAssertEqual(latest.count, 2)
                XCTAssertTrue(latest.allSatisfy { $0.snapshot.kind == .balance && $0.snapshot.amount == 3 })
                XCTAssertTrue(blocked)
                checked.fulfill()
            }
            wait(for: [checked], timeout: 3)
        }
        try Data("broken".utf8).write(to: reader.stateURL, options: .atomic)
        verifyUntrusted()
        try validState.write(to: reader.stateURL, options: .atomic)
        try withDatabase { db in
            try execute(db, sql: "BEGIN EXCLUSIVE")
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            verifyUntrusted()
        }
        try FileManager.default.removeItem(at: reader.stateURL)
        verifyUntrusted()
        try validState.write(to: reader.stateURL, options: .atomic)
        let inactive = try JSONSerialization.data(withJSONObject: ["apps": ["codex": ["mode": "direct"]]])
        try inactive.write(to: reader.stateURL, options: .atomic)
        let exited = expectation(description: "confirmed direct clears aggregation")
        coordinator.performAsync {
            XCTAssertFalse(coordinator.refreshAggregation(reader: reader, force: false))
            XCTAssertTrue(latest.isEmpty)
            XCTAssertFalse(blocked)
            exited.fulfill()
        }
        wait(for: [exited], timeout: 3)
        coordinator.stopAggregation()
    }

    func testConfirmedMissingAggregationStateExitsAfterAbsenceWindow() throws {
        try addAggregationMembers(1)
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let url = temporaryDirectoryURL.appendingPathComponent("live-state.json")
        try JSONSerialization.data(withJSONObject: ["apps": ["codex": ["mode": "proxy", "attached": true,
            "proxy_route": "codex-custom", "stack": ["enabled": true, "members": ["member-0"]]]]]).write(to: url, options: .atomic)
        let reader = CCSwitchAggregationRepository(repository: repository, stateURL: url, isRunning: { true }, now: { clock.now })
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "3") }
        let ready = expectation(description: "trusted members")
        var latest: [AggregatedProviderDisplay] = []
        var blocked = false
        var announced = false
        let coordinator = aggregationCoordinator { displays, protection in
            latest = displays; blocked = protection
            if displays.count == 2 && displays.allSatisfy({ $0.status == .fresh }) && !announced {
                announced = true; ready.fulfill()
            }
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [ready], timeout: 3)
        try FileManager.default.removeItem(at: url)
        let missing = expectation(description: "transient missing retains members")
        coordinator.performAsync {
            XCTAssertTrue(coordinator.refreshAggregation(reader: reader, force: false))
            XCTAssertEqual(latest.count, 2)
            XCTAssertTrue(blocked)
            missing.fulfill()
        }
        wait(for: [missing], timeout: 3)
        clock.advance(by: CCSwitchAggregationRepository.confirmedAbsenceInterval)
        let exited = expectation(description: "confirmed absence clears aggregation")
        coordinator.performAsync {
            XCTAssertFalse(coordinator.refreshAggregation(reader: reader, force: false))
            XCTAssertTrue(latest.isEmpty)
            XCTAssertTrue(blocked)
            exited.fulfill()
        }
        wait(for: [exited], timeout: 3)
        coordinator.stopAggregation()
    }

    func testQuickSwitchSummarySameProviderIDIsIsolatedByClient() throws {
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET id='codex-custom' WHERE id='claude-custom' AND app_type='claude'")
        }
        DelayedBalanceURLProtocol.setHandler { request in
            DelayedBalanceURLProtocol.success(amount: request.url?.host == "claude.provider.test" ? "3" : "13")
        }
        let changed = expectation(description: "both independent summaries")
        changed.expectedFulfillmentCount = 2
        let actions = makeActions { _ in changed.fulfill() }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: OfficialQuotaClient(),
            balanceAPIClient: BalanceAPIClient(session: session), actions: actions)
        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex, providerIDs: ["codex-custom"])
        coordinator.refreshQuickSwitchSummaries(force: true, for: .claude, providerIDs: ["codex-custom"])
        wait(for: [changed], timeout: 3)
        XCTAssertEqual(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .defaultValue, client: .codex)["codex-custom"], "$13.00")
        XCTAssertEqual(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .defaultValue, client: .claude)["codex-custom"], "$3.00")
    }
}

extension ProviderRefreshCoordinatorTests {
    func testLegacyMissingStateDoesNotDisableDirectQuickSwitch() throws {
        try withDatabase { db in
            try execute(db, sql: "UPDATE proxy_config SET enabled = 0, live_takeover_active = 0 WHERE app_type = 'codex'")
        }
        let reader = CCSwitchAggregationRepository(repository: repository,
            read: { _ in throw CocoaError(.fileReadNoSuchFile) })
        let checked = expectation(description: "legacy direct fallback")
        var blocked = true
        let coordinator = aggregationCoordinator { displays, protection in
            XCTAssertTrue(displays.isEmpty)
            blocked = protection
        }
        coordinator.performAsync {
            XCTAssertFalse(coordinator.refreshAggregation(reader: reader, force: false))
            XCTAssertFalse(blocked)
            checked.fulfill()
        }
        wait(for: [checked], timeout: 2)
        coordinator.stopAggregation()
    }
}

extension ProviderRefreshCoordinatorTests {
    func testUntrustedAggregationRetriesAndRecoversAfterAtomicReplacement() throws {
        try addAggregationMembers(1)
        let reader = try aggregationFixture(members: ["member-0"])
        let valid = try Data(contentsOf: reader.stateURL)
        let initial = expectation(description: "initial trusted aggregation")
        let recovered = expectation(description: "retry recovered without manual refresh")
        var phase = 0
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "3") }
        let coordinator = aggregationCoordinator { displays, blocked in
            XCTAssertEqual(displays.count, 2)
            XCTAssertTrue(blocked)
            if displays.allSatisfy({ $0.status == .fresh }) {
                if phase == 0 { phase = 1; initial.fulfill() }
                else if phase == 2 { phase = 3; recovered.fulfill() }
            }
        }
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [initial], timeout: 3)
        coordinator.performAsync {
            do {
                try Data("incomplete".utf8).write(to: reader.stateURL, options: .atomic)
                XCTAssertTrue(coordinator.refreshAggregation(reader: reader, force: false))
                phase = 2
                try valid.write(to: reader.stateURL, options: .atomic)
            } catch { XCTFail("fixture replacement failed") }
        }
        wait(for: [recovered], timeout: 4)
        coordinator.stopAggregation()
    }
}

// MARK: - PR #508 review regressions

private final class AtomicFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func clear() { lock.lock(); value = false; lock.unlock() }
}

extension ProviderRefreshCoordinatorTests {
    private static let claudeUsageB = Data(#"{"five_hour":{"utilization":90,"resets_at":"2099-01-01T05:00:00Z"},"seven_day":{"utilization":95,"resets_at":"2099-01-07T00:00:00Z"}}"#.utf8)

    private func preferences(interval: TimeInterval) -> AppPreferences {
        let suite = "PR508.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.officialUsageRefreshInterval = interval
        return preferences
    }

    private static let claudeLowUsage = Data(#"{"five_hour":{"utilization":82,"resets_at":"2099-01-01T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2099-01-07T00:00:00Z"}}"#.utf8)

    /// Wires a real notification coordinator exactly like the app composition.
    private func notificationHarness(providerID: String, agent: BalanceNotificationAgent = .claude) -> (BalanceNotificationCoordinator, FakeBalanceNotificationClient, () -> Void) {
        let client = FakeBalanceNotificationClient(status: .authorized, requestResult: true)
        let suite = "PR508.Notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let notifications = BalanceNotificationCoordinator(defaults: defaults, client: client)
        let enable = {
            notifications.setGlobalEnabled(true)
            notifications.setAgentEnabled(true, agent: agent)
            notifications.setProviderEnabled(true, agent: agent, providerID: providerID)
        }
        return (notifications, client, enable)
    }

    private func wire(_ actions: inout ProviderRefreshActions, to notifications: BalanceNotificationCoordinator) {
        actions.notificationSnapshot = { client, providerID, snapshot in
            notifications.process(snapshot: snapshot, agent: client == .claude ? .claude : .gpt, providerID: providerID)
        }
        actions.notificationSamplesInvalidated = { client, ids in
            notifications.invalidateCurrentSamples(agent: client == .claude ? .claude : .gpt, providerIDs: ids)
        }
        actions.notificationAccountScopeChanged = { client, scope in
            notifications.setCurrentAccountScope(scope, agent: client == .claude ? .claude : .gpt)
        }
    }

    func testQuickSwitchDoesNotReloadLargeProviderListOnEveryThreeSecondPoll() throws {
        for index in 0..<250 {
            try withDatabase { db in
                try execute(db, sql: """
                    INSERT INTO providers VALUES (
                        'codex-bench-\(index)', 'Benchmark \(index)',
                        '{"api_key":"fixture-key","base_url":"https://provider.example"}',
                        '{"usage_script":{"enabled":true,"baseUrl":"https://provider.example","code":"url: `{{baseUrl}}/usage`"}}',
                        'custom', 'https://provider.example', 'codex', 0, \(index + 10), \(index + 10)
                    )
                    """)
            }
        }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let readsLock = NSLock()
        var reads = 0
        repository.loadSummarySourcesObserver = { _ in readsLock.lock(); reads += 1; readsLock.unlock() }
        defer { repository.loadSummarySourcesObserver = nil }
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "10.00") }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: OfficialQuotaClient(session: session),
            actions: makeActions(), now: { clock.now })

        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex, providerIDs: ["codex-custom"])
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, DelayedBalanceURLProtocol.requestCount == 0 { Thread.sleep(forTimeInterval: 0.005) }
        waitForCoordinator(coordinator)
        XCTAssertEqual(repository.loadSummarySources(appType: "codex").count, 252)
        readsLock.lock(); let initialReads = reads; readsLock.unlock()
        XCTAssertGreaterThan(initialReads, 0)

        for _ in 0..<19 {
            clock.advance(by: 3)
            coordinator.refreshQuickSwitchSummaries(force: false, for: .codex, providerIDs: ["codex-custom"])
            waitForCoordinator(coordinator)
        }
        readsLock.lock(); XCTAssertEqual(reads, initialReads, "60 seconds of timer polls must not reload all 252 provider configurations"); readsLock.unlock()

        clock.advance(by: 3)
        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex, providerIDs: ["codex-custom"])
        waitForCoordinator(coordinator)
        readsLock.lock(); XCTAssertGreaterThan(reads, initialReads); readsLock.unlock()
    }

    func testConcurrentSummaryCompletionsReadOnlyTheirOwnProviderRows() throws {
        try withDatabase { db in
            for index in 0..<250 {
                try execute(db, sql: """
                    INSERT INTO providers VALUES (
                        'codex-bench-\(index)', 'Benchmark \(index)',
                        '{"api_key":"fixture-key","base_url":"https://provider.example"}',
                        '{"usage_script":{"enabled":true,"baseUrl":"https://provider.example","code":"url: `{{baseUrl}}/usage`"}}',
                        'custom', 'https://provider.example', 'codex', 0, \(index + 10), \(index + 10)
                    )
                    """)
            }
        }
        let sources = repository.loadSummarySources(appType: "codex")
        XCTAssertTrue(sources.contains(where: \.isOfficial), "the official callback path must be covered too")
        let readsLock = NSLock()
        var fullReads = 0
        var rowReads: [[String]] = []
        repository.loadSummarySourcesObserver = { ids in
            readsLock.lock(); defer { readsLock.unlock() }
            if let ids { rowReads.append(ids) } else { fullReads += 1 }
        }
        defer { repository.loadSummarySourcesObserver = nil }
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "10.00") }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: "fixture")),
            balanceAPIClient: BalanceAPIClient(session: session), actions: makeActions())

        coordinator.refreshQuickSwitchSummaries(force: true, for: .codex)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            readsLock.lock(); let done = rowReads.count >= sources.count; readsLock.unlock()
            if done { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        waitForCoordinator(coordinator)

        readsLock.lock(); defer { readsLock.unlock() }
        XCTAssertEqual(fullReads, 1, "only the refresh itself may read the whole provider list")
        XCTAssertEqual(rowReads.count, sources.count, "each completion verifies exactly its own row")
        XCTAssertTrue(rowReads.allSatisfy { $0.count == 1 })
        XCTAssertEqual(Set(rowReads.map { $0[0] }), Set(sources.map(\.id)))
    }

    func testQuickSwitchPollsSkipAggregationMembersAndScriptlessAPIProvidersUntilTTL() throws {
        try addAggregationMembers(1)
        try withDatabase { db in
            try execute(db, sql: """
                INSERT INTO providers VALUES (
                    'codex-no-script', 'No Script', '{"api_key":"fixture-key","base_url":"https://provider.example"}',
                    '{}', 'custom', 'https://provider.example', 'codex', 0, 20, 20
                )
                """)
            try execute(db, sql: "INSERT INTO providers SELECT 'codex-direct', 'Codex Direct', settings_config, meta, category, website_url, app_type, 0, 21, 21 FROM providers WHERE id='codex-custom'")
            // Official completions reread providers; this test isolates API members.
            try execute(db, sql: "DELETE FROM providers WHERE app_type = 'codex' AND category = 'official'")
        }
        let reader = try aggregationFixture(members: ["member-0"])
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let readsLock = NSLock()
        var reads = 0
        DelayedBalanceURLProtocol.setHandler { _ in DelayedBalanceURLProtocol.success(amount: "10.00") }
        let aggregated = expectation(description: "aggregation member fresh")
        let direct = expectation(description: "direct API summary delivered")
        var aggregatedDelivered = false
        var actions = makeActions()
        actions.aggregationChanged = { displays, _ in
            guard !aggregatedDelivered, displays.contains(where: { $0.status == .fresh }) else { return }
            aggregatedDelivered = true
            aggregated.fulfill()
        }
        actions.notificationSnapshot = { _, providerID, _ in
            if providerID == "codex-direct" { direct.fulfill() }
        }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: "fixture")),
            balanceAPIClient: BalanceAPIClient(session: session), actions: actions, now: { clock.now })
        coordinator.performAsync { _ = coordinator.refreshAggregation(reader: reader, force: true) }
        wait(for: [aggregated], timeout: 3)
        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        wait(for: [direct], timeout: 3)
        waitForCoordinator(coordinator)
        repository.loadSummarySourcesObserver = { _ in readsLock.lock(); reads += 1; readsLock.unlock() }
        defer { repository.loadSummarySourcesObserver = nil }

        for _ in 0..<19 {
            clock.advance(by: 3)
            coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
            waitForCoordinator(coordinator)
        }
        readsLock.lock(); XCTAssertEqual(reads, 0, "aggregation members and providers without a script must not force a reload on every poll"); readsLock.unlock()

        clock.advance(by: 3)
        coordinator.refreshQuickSwitchSummaries(force: false, for: .codex)
        waitForCoordinator(coordinator)
        readsLock.lock(); XCTAssertGreaterThan(reads, 0, "the shared 60-second API TTL still reloads"); readsLock.unlock()
    }

    func testManualQuickSwitchRefreshHonorsCodexOfficialIntervalButStillRefreshesAPIBalances() throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let lock = NSLock()
        var officialRequests = 0
        var balanceRequests = 0
        DelayedBalanceURLProtocol.setHandler { request in
            lock.lock(); defer { lock.unlock() }
            if request.url?.host == "chatgpt.com" {
                officialRequests += 1
                return .init(data: Data("{}".utf8), statusCode: 200)
            }
            balanceRequests += 1
            return DelayedBalanceURLProtocol.success(amount: "\(balanceRequests)")
        }
        let coordinator = makeCoordinator(repository: repository,
            officialQuotaClient: OfficialQuotaClient(session: session,
                credentialReader: FixtureCredentialReader(codexToken: "fixture"),
                parser: IncrementingOfficialQuotaParser(counter: IncrementingCounter())),
            balanceAPIClient: BalanceAPIClient(session: session),
            actions: makeActions(), refreshPreferences: preferences(interval: 180), now: { clock.now })
        func manualRefresh(expectedTransport: Int) {
            coordinator.refreshQuickSwitchSummaries(force: true, for: .codex)
            waitForCoordinator(coordinator)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, DelayedBalanceURLProtocol.requestCount < expectedTransport {
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertTrue(DelayedBalanceURLProtocol.waitUntilIdle())
            waitForCoordinator(coordinator)
        }

        manualRefresh(expectedTransport: 2)
        clock.advance(by: 10)
        manualRefresh(expectedTransport: 3)
        clock.advance(by: 169)                      // t = 179
        manualRefresh(expectedTransport: 4)
        lock.lock()
        XCTAssertEqual(officialRequests, 1, "repeated manual refresh must not bypass the official interval")
        XCTAssertEqual(balanceRequests, 3, "manual refresh still refreshes API balances immediately")
        lock.unlock()
        clock.advance(by: 1)                        // t = 180
        manualRefresh(expectedTransport: 6)
        lock.lock(); XCTAssertEqual(officialRequests, 2); lock.unlock()
    }
}

// MARK: - PR #508 second review regressions

extension ProviderRefreshCoordinatorTests {
    private static let claudeUsageC = Data(#"{"five_hour":{"utilization":50,"resets_at":"2099-01-01T05:00:00Z"},"seven_day":{"utilization":60,"resets_at":"2099-01-07T00:00:00Z"}}"#.utf8)

    private func claudeSummaryText(_ coordinator: ProviderRefreshCoordinator, providerID: String) -> String? {
        coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour, client: .claude)[providerID]
    }

}

// MARK: - INT-1: Claude official path on the quota modules

extension TestClock: SchedulerClock {}

/// Lets a test switch the Claude token (Keychain) independently of the account file.
private final class SwitchableClaudeReader: OfficialQuotaCredentialReading {
    private let lock = NSLock()
    private var token: String?
    init(token: String?) { self.token = token }
    func set(_ value: String?) { lock.lock(); token = value; lock.unlock() }
    func codexAccessToken() -> String? { nil }
    func codexAccountProfile() -> CodexAccountProfile? { nil }
    func claudeAccessToken() -> String? { lock.lock(); defer { lock.unlock() }; return token }
}

/// One account file plus the pipeline that watches it.
private final class ClaudePipelineHarness {
    let pipeline: ClaudeQuotaPipeline
    let identity: ClaudeAccountIdentityProvider
    let directory: URL

    init(directory: URL, pipeline: ClaudeQuotaPipeline, identity: ClaudeAccountIdentityProvider) {
        self.directory = directory
        self.pipeline = pipeline
        self.identity = identity
    }

    var configurationURL: URL { directory.appendingPathComponent("claude.json") }

    func writeAccount(_ uuid: String, email: String) throws {
        let object = ["oauthAccount": ["accountUuid": uuid, "emailAddress": email, "organizationUuid": "org"]]
        try JSONSerialization.data(withJSONObject: object).write(to: configurationURL, options: .atomic)
    }

    /// Account switches reach the pipeline through file events; wait for the epoch bump.
    func waitForEpoch(after epoch: AccountEpoch, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while identity.accountEpoch == epoch, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertNotEqual(identity.accountEpoch, epoch, "account change was not observed", file: file, line: line)
    }
}

extension ProviderRefreshCoordinatorTests {
    private func makeClaudeHarness(
        official: OfficialQuotaClient, clock: TestClock, accountUUID: String? = "account-a", email: String = "a@example.com"
    ) throws -> ClaudePipelineHarness {
        let directory = temporaryDirectoryURL.appendingPathComponent("claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityQueue = DispatchQueue(label: "test.claude.identity")
        let identity = ClaudeAccountIdentityProvider(
            configurationURL: directory.appendingPathComponent("claude.json"),
            workQueue: identityQueue, coalescingInterval: 0.02, now: { clock.now })
        var configuration = FetchSchedulerConfiguration()
        configuration.coalescingWindow = 0.02
        let pipeline = ClaudeQuotaPipeline(
            client: official, identity: identity, identityQueue: identityQueue,
            stateDirectory: directory.appendingPathComponent("state", isDirectory: true),
            schedulerClock: clock, schedulerConfiguration: configuration, now: { clock.now })
        let harness = ClaudePipelineHarness(directory: directory, pipeline: pipeline, identity: identity)
        if let accountUUID { try harness.writeAccount(accountUUID, email: email) }
        return harness
    }

    private func claudeActions(
        activeClaude: Bool = true,
        render: @escaping (Snapshot) -> Void
    ) -> ProviderRefreshActions {
        ProviderRefreshActions(
            currentProvider: { [repository] in repository?.loadCurrent(appType: $0.appType) },
            isActiveClient: { $0 == .claude && activeClaude }, render: render,
            storeClientSnapshot: { _, _, _ in }, quickSwitchSummaryChanged: { _ in })
    }

    /// Requests reach transport after the scheduler's short coalescing window.
    private func waitForRequestCount(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while DelayedBalanceURLProtocol.requestCount < count, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, count, file: file, line: line)
    }

    /// For "no request happens" assertions: outlast the coalescing window first.
    private func settleQuietly(_ coordinator: ProviderRefreshCoordinator, _ harness: ClaudePipelineHarness) {
        settle(coordinator, harness)
        Thread.sleep(forTimeInterval: 0.2)
        settle(coordinator, harness)
    }

    private func settle(_ coordinator: ProviderRefreshCoordinator, _ harness: ClaudePipelineHarness) {
        harness.pipeline.waitUntilIdle()
        waitForCoordinator(coordinator)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private static let claudeFallback = Data(#"{"five_hour":{"utilization":23,"resets_at":"2099-01-01T05:00:00Z"},"seven_day":{"utilization":41,"resets_at":"2099-01-07T00:00:00Z"}}"#.utf8)

    func testClaudeStandardRefreshRendersMergedWindowsWithStatusSlotAndHonorsCadence() throws {
        let current = try useClaudeOfficialProvider()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        DelayedBalanceURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer claude-fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            return .init(data: Self.claudeUsage, statusCode: 200)
        }
        let official = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "claude-fixture"), now: { clock.now })
        let harness = try makeClaudeHarness(official: official, clock: clock)
        let start = clock.now
        let rendered = (0..<2).map { expectation(description: "Claude quota publication \($0)") }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: claudeActions { snapshot in
                XCTAssertEqual(snapshot.kind, .official)
                XCTAssertEqual(snapshot.provider, "Claude Official")
                XCTAssertEqual(snapshot.officialQuotaWindows.map(\.remaining), [77, 59])
                XCTAssertTrue(snapshot.officialQuotaWindows.allSatisfy { $0.resetAt != nil })
                XCTAssertEqual(snapshot.resetForecast, .unavailable, "Claude never inherits Codex reset forecasts")
                XCTAssertNil(snapshot.bankedReset)
                XCTAssertNotNil(snapshot.notificationAccountScope)
                // The slot shows "refreshing" while a read is in flight and the read time afterwards.
                if snapshot.quotaStatus == .official(at: start) { rendered[0].fulfill() }
                if snapshot.quotaStatus == .official(at: start.addingTimeInterval(180)) { rendered[1].fulfill() }
            }, claudeQuota: harness.pipeline, now: { clock.now })
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        wait(for: [rendered[0]], timeout: 3)

        clock.advance(by: 179)
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        settleQuietly(coordinator, harness)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1, "the calibration interval is at least three minutes")
        clock.advance(by: 1)
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        wait(for: [rendered[1]], timeout: 3)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2)
    }

    func testClaudeStandardSummaryAndActivityBurstShareOneScheduledRequest() throws {
        let current = try useClaudeOfficialProvider()
        DelayedBalanceURLProtocol.setHandler { _ in .init(data: Self.claudeUsage, statusCode: 200) }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let official = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "fixture"), now: { clock.now })
        let harness = try makeClaudeHarness(official: official, clock: clock)
        let first = expectation(description: "initial quota")
        var rendered = 0
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: claudeActions { snapshot in
                XCTAssertEqual(snapshot.kind, .official, "a burst must not replace success with an error")
                rendered += 1
                first.fulfill()
            }, claudeQuota: harness.pipeline, now: { clock.now })
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: true, switched: true)
        coordinator.refreshQuickSwitchSummaries(force: true, for: .claude)
        coordinator.prefetchCurrentBalance(for: .claude)
        wait(for: [first], timeout: 3)
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: true, switched: false)
        coordinator.refreshQuickSwitchSummaries(force: true, for: .claude)
        settleQuietly(coordinator, harness)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        XCTAssertEqual(rendered, 1)
        XCTAssertFalse(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour, client: .claude).isEmpty)
    }

    func testInactiveClaudePrefetchStoresSnapshotAndNotifiesOncePerProvider() throws {
        let current = try useClaudeOfficialProvider()
        DelayedBalanceURLProtocol.setHandler { _ in .init(data: Self.claudeUsage, statusCode: 200) }
        let official = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "claude-fixture"))
        let harness = try makeClaudeHarness(official: official, clock: TestClock(date: Date()))
        let stored = expectation(description: "inactive Claude quota cached")
        let notified = expectation(description: "adapter notified")
        var actions = ProviderRefreshActions(
            currentProvider: { [repository] in repository?.loadCurrent(appType: $0.appType) },
            isActiveClient: { $0 == .codex },
            render: { _ in XCTFail("inactive Claude must not replace active Codex") },
            storeClientSnapshot: { client, id, snapshot in
                XCTAssertEqual(client, .claude)
                XCTAssertEqual(id, current.id)
                XCTAssertEqual(snapshot.officialQuotaWindows.map(\.remaining), [77, 59])
                stored.fulfill()
            }, quickSwitchSummaryChanged: { _ in })
        actions.notificationSnapshot = { client, id, snapshot in
            XCTAssertEqual(client, .claude)
            XCTAssertEqual(id, current.id)
            XCTAssertEqual(snapshot.officialQuotaWindows.map(\.remaining), [77, 59])
            notified.fulfill()
        }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: actions, claudeQuota: harness.pipeline)
        coordinator.prefetchCurrentBalance(for: .claude)
        wait(for: [stored, notified], timeout: 3)
        settle(coordinator, harness)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 1)
        XCTAssertFalse(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour, client: .claude).isEmpty)
        XCTAssertTrue(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour, client: .codex).isEmpty)
    }

    func testClaudeFailuresWithoutCachedDataRenderErrorsWithFailureStatus() throws {
        let current = try useClaudeOfficialProvider()
        for (token, status, data) in [
            (nil as String?, 200, Self.claudeUsage),
            ("fixture", 401, Data()),
            ("fixture", 429, Data()),
            ("fixture", 200, Data("not-json".utf8)),
            ("fixture", 200, Data("{}".utf8))
        ] {
            DelayedBalanceURLProtocol.setHandler { _ in .init(data: data, statusCode: status) }
            let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
            let official = OfficialQuotaClient(session: session,
                credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: token), now: { clock.now })
            let harness = try makeClaudeHarness(official: official, clock: clock)
            let rendered = expectation(description: "Claude error replaces placeholder (\(status), \(token ?? "no token"))")
            let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
                actions: claudeActions { snapshot in
                    XCTAssertEqual(snapshot.kind, .error)
                    XCTAssertEqual(snapshot.provider, "Claude Official")
                    guard case .error? = snapshot.quotaStatus else { return XCTFail("error cards carry the failure status") }
                    if status == 429 { XCTAssertTrue(snapshot.message?.contains("429") == true) }
                    rendered.fulfill()
                }, claudeQuota: harness.pipeline, now: { clock.now })
            coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: true, switched: false)
            wait(for: [rendered], timeout: 3)
            coordinator.stop()
        }
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 4, "missing credentials must not start transport")
    }

    func testClaudeLatePrefetchIsDroppedAfterProviderConfigurationChanges() throws {
        _ = try useClaudeOfficialProvider()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DelayedBalanceURLProtocol.setHandler { _ in
            started.signal()
            return .init(data: Self.claudeUsage, statusCode: 200, delayUntil: release)
        }
        let official = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "fixture"))
        let harness = try makeClaudeHarness(official: official, clock: TestClock(date: Date()))
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: ProviderRefreshActions(
                currentProvider: { [repository] in repository?.loadCurrent(appType: $0.appType) },
                isActiveClient: { _ in true },
                render: { _ in XCTFail("obsolete configuration must not render") },
                storeClientSnapshot: { _, _, _ in XCTFail("obsolete configuration must not cache") },
                quickSwitchSummaryChanged: { _ in }), claudeQuota: harness.pipeline)
        coordinator.prefetchCurrentBalance(for: .claude)
        waitForEvent(started)
        try withDatabase { database in
            try execute(database, sql: "UPDATE providers SET name = 'Changed Claude' WHERE app_type = 'claude'")
        }
        release.signal()
        XCTAssertTrue(DelayedBalanceURLProtocol.waitUntilIdle())
        settle(coordinator, harness)
        XCTAssertTrue(coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour, client: .claude).isEmpty)
    }

    /// Issue #521 review case: several official entries share one request, the first entry is
    /// edited and the account is switched while the request is in flight. Nothing may publish
    /// the previous account's quota, and the new account is read right after.
    func testAccountSwitchWhileSharedRequestIsInFlightPublishesNoPreviousAccountQuota() throws {
        let current = try useClaudeOfficialProvider()
        try withDatabase { db in
            for index in 0..<2 {
                try execute(db, sql: "INSERT INTO providers SELECT 'claude-official-\(index)', name, settings_config, meta, category, website_url, app_type, 0, \(index + 20), \(index + 20) FROM providers WHERE app_type = 'claude' LIMIT 1")
            }
        }
        let started = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let accountB = AtomicFlag()
        DelayedBalanceURLProtocol.setHandler { _ in
            if accountB.isSet { return .init(data: Self.claudeUsageB, statusCode: 200) }
            started.signal()
            return .init(data: Self.claudeUsage, statusCode: 200, delayUntil: releaseA)
        }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let official = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "token"), now: { clock.now })
        let harness = try makeClaudeHarness(official: official, clock: clock)
        let lock = NSLock()
        var renderedRemaining: [[Double]] = []
        let accountBRendered = expectation(description: "account B renders")
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: claudeActions { snapshot in
                guard snapshot.kind == .official else { return }
                lock.lock(); renderedRemaining.append(snapshot.officialQuotaWindows.map(\.remaining)); lock.unlock()
                if snapshot.officialQuotaWindows.map(\.remaining) == [10, 5] { accountBRendered.fulfill() }
            }, claudeQuota: harness.pipeline, now: { clock.now })
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: true)
        coordinator.refreshQuickSwitchSummaries(force: true, for: .claude)
        waitForEvent(started)

        try withDatabase { database in
            try execute(database, sql: "UPDATE providers SET name = 'Edited' WHERE id = '\(current.id)'")
        }
        let epoch = harness.identity.accountEpoch
        try harness.writeAccount("account-b", email: "b@example.com")
        harness.waitForEpoch(after: epoch)
        accountB.set()
        releaseA.signal()
        // The next poll targets the edited Provider revision.
        let edited = try XCTUnwrap(repository.loadCurrent(appType: "claude"))
        coordinator.refreshStandardProvider(current: edited, client: .claude, forceBalance: false, switched: false)

        wait(for: [accountBRendered], timeout: 5)
        settle(coordinator, harness)
        lock.lock(); let rendered = renderedRemaining; lock.unlock()
        XCTAssertFalse(rendered.contains([77, 59]), "the previous account's quota must never be published")
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2, "one shared request per account")
        let summaries = coordinator.quickSwitchSummariesSnapshot(preferredQuotaWindow: .fiveHour, client: .claude)
        XCTAssertFalse(summaries.values.contains { $0.contains("77") }, "no summary may show account A's value")
    }

    func testClaudeRateLimitKeepsSameAccountQuotaVisibleAsErrorAndInvalidatesNotificationSample() throws {
        let current = try useClaudeOfficialProvider()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let rateLimited = AtomicFlag()
        DelayedBalanceURLProtocol.setHandler { _ in
            rateLimited.isSet ? .init(data: Data(), statusCode: 429) : .init(data: Self.claudeUsage, statusCode: 200)
        }
        let official = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "fixture"), now: { clock.now })
        let harness = try makeClaudeHarness(official: official, clock: clock)
        let lock = NSLock()
        var renders: [Snapshot] = []
        var next: XCTestExpectation?
        var awaitStale = false
        var notified: [Snapshot] = []
        var invalidated: [Set<String>] = []
        var actions = claudeActions { snapshot in
            lock.lock(); renders.append(snapshot); lock.unlock()
            if snapshot.kind == .official, (snapshot.staleReason != nil) == awaitStale { next?.fulfill(); next = nil }
        }
        actions.notificationSnapshot = { _, _, snapshot in lock.lock(); notified.append(snapshot); lock.unlock() }
        actions.notificationSamplesInvalidated = { _, ids in lock.lock(); invalidated.append(ids); lock.unlock() }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: actions, claudeQuota: harness.pipeline, now: { clock.now })

        next = expectation(description: "fresh quota")
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        wait(for: [next!], timeout: 3)
        let fresh = try XCTUnwrap(renders.last)
        XCTAssertNil(harness.pipeline.manualRefreshBlockedUntil())

        rateLimited.set()
        awaitStale = true
        clock.advance(by: 180)
        next = expectation(description: "rate-limited, data kept")
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        wait(for: [next!], timeout: 3)
        let stale = try XCTUnwrap(renders.last)
        XCTAssertEqual(stale.officialQuotaWindows.map(\.remaining), fresh.officialQuotaWindows.map(\.remaining))
        XCTAssertEqual(stale.date, fresh.date, "the card keeps the last successful refresh time")
        XCTAssertEqual(stale.quotaStatus, .error(at: fresh.date))
        XCTAssertTrue(stale.staleReason?.contains("429") == true)
        let until = try XCTUnwrap(harness.pipeline.manualRefreshBlockedUntil(), "menu refresh waits for the server cooldown")
        XCTAssertGreaterThanOrEqual(until.timeIntervalSince(clock.now), QuotaConstants.minimumCooldown - 1)
        settle(coordinator, harness)
        lock.lock()
        XCTAssertEqual(notified.count, 1, "kept 429 data is never a real notification sample")
        XCTAssertTrue(invalidated.contains { $0.contains(current.id) }, "notifications learn the stored sample is no longer current")
        lock.unlock()

        // The cooldown survives until its end, then a real sample is published again.
        clock.advance(by: 300)
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: true, switched: false, userInitiated: true)
        settle(coordinator, harness)
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 2, "a manual refresh cannot bypass the 429 cooldown")
        rateLimited.clear()
        awaitStale = false
        clock.advance(by: until.timeIntervalSince(clock.now) + 1)
        XCTAssertNil(harness.pipeline.manualRefreshBlockedUntil())
        next = expectation(description: "recovered quota")
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: true, switched: false, userInitiated: true)
        wait(for: [next!], timeout: 3)
        settle(coordinator, harness)
        lock.lock(); XCTAssertEqual(notified.count, 2); lock.unlock()
    }

    func testClaudeTokenRefreshForSameAccountKeepsDataButAnotherAccountClearsIt() throws {
        let current = try useClaudeOfficialProvider()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        DelayedBalanceURLProtocol.setHandler { _ in .init(data: Self.claudeUsage, statusCode: 200) }
        let reader = SwitchableClaudeReader(token: "token-1")
        let official = OfficialQuotaClient(session: session, credentialReader: reader, now: { clock.now })
        let harness = try makeClaudeHarness(official: official, clock: clock)
        let lock = NSLock()
        var kinds: [Snapshot.Kind] = []
        var next: XCTestExpectation?
        var scopes: [String?] = []
        var actions = claudeActions { snapshot in
            lock.lock(); kinds.append(snapshot.kind); lock.unlock()
            if snapshot.kind == .official { next?.fulfill(); next = nil }
        }
        actions.notificationAccountScopeChanged = { _, scope in lock.lock(); scopes.append(scope); lock.unlock() }
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: actions, claudeQuota: harness.pipeline, now: { clock.now })

        next = expectation(description: "token 1")
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        wait(for: [next!], timeout: 3)

        reader.set("token-2")
        clock.advance(by: 180)
        next = expectation(description: "rotated token, same account")
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        wait(for: [next!], timeout: 3)
        settle(coordinator, harness)
        lock.lock()
        XCTAssertFalse(kinds.contains(.placeholder), "a refreshed token for the same account is not an account switch")
        XCTAssertEqual(Set(scopes.compactMap { $0 }).count, 1, "notification progress keeps one identity across token refresh")
        lock.unlock()

        // Both automatic reads spent the shared request budget; let one token refill.
        clock.advance(by: QuotaConstants.requestTokenRefillInterval)
        let epoch = harness.identity.accountEpoch
        next = expectation(description: "another account")
        try harness.writeAccount("account-b", email: "b@example.com")
        harness.waitForEpoch(after: epoch)
        wait(for: [next!], timeout: 5)
        settle(coordinator, harness)
        lock.lock()
        XCTAssertTrue(kinds.contains(.placeholder), "a different account clears the previous account's quota")
        XCTAssertEqual(Set(scopes.compactMap { $0 }).count, 2)
        lock.unlock()
        XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, 3, "the new account is read without waiting for the old interval")
    }

    func testClaudeSummaryRequestsHonorTheThreeMinuteFloorForEveryCalibrationSetting() throws {
        _ = try useClaudeOfficialProvider()
        DelayedBalanceURLProtocol.setHandler { _ in .init(data: Self.claudeUsage, statusCode: 200) }
        for interval: TimeInterval in [60, 150] {
            let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
            let official = OfficialQuotaClient(session: session,
                credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "summary-\(Int(interval))"), now: { clock.now })
            let harness = try makeClaudeHarness(official: official, clock: clock)
            let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
                actions: makeActions(), refreshPreferences: preferences(interval: interval),
                claudeQuota: harness.pipeline, now: { clock.now })
            let before = DelayedBalanceURLProtocol.requestCount
            coordinator.refreshQuickSwitchSummaries(force: false, for: .claude)
            waitForRequestCount(before + 1)
            settle(coordinator, harness)

            clock.advance(by: 179)
            coordinator.refreshQuickSwitchSummaries(force: false, for: .claude)
            settleQuietly(coordinator, harness)
            XCTAssertEqual(DelayedBalanceURLProtocol.requestCount, before + 1, "setting \(Int(interval)) s is only an upper bound")
            clock.advance(by: 1)
            coordinator.refreshQuickSwitchSummaries(force: false, for: .claude)
            waitForRequestCount(before + 2)
            settle(coordinator, harness)
            coordinator.stop()
            coordinators.removeAll { $0 === coordinator }
        }
    }

    func testClaudeAccountSwitchNeverAlertsFromPreviousAccountAndNewAccountAlertsNormally() throws {
        let current = try useClaudeOfficialProvider()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let bState = AtomicFlag()
        DelayedBalanceURLProtocol.setHandler { _ in
            bState.isSet ? .init(data: Data(), statusCode: 429) : .init(data: Self.claudeLowUsage, statusCode: 200)
        }
        let official = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "token"), now: { clock.now })
        let harness = try makeClaudeHarness(official: official, clock: clock)
        let (notifications, notificationClient, enableNotifications) = notificationHarness(providerID: current.id)
        var actions = claudeActions { _ in }
        wire(&actions, to: notifications)
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: actions, claudeQuota: harness.pipeline, now: { clock.now })

        // Account A's low sample is stored while notifications are still off.
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        waitForRequestCount(1)
        settle(coordinator, harness)
        enableNotifications()
        XCTAssertTrue(notificationClient.deliveries.isEmpty)

        // Account B signs in and its first read is rate limited: A's low sample must not alert for B.
        bState.set()
        clock.advance(by: QuotaConstants.requestTokenRefillInterval)
        let epoch = harness.identity.accountEpoch
        try harness.writeAccount("account-b", email: "b@example.com")
        harness.waitForEpoch(after: epoch)
        waitForRequestCount(2)
        settle(coordinator, harness)
        notifications.refreshPermission()
        XCTAssertTrue(notificationClient.deliveries.isEmpty, "account A's low sample must not alert for account B")
        XCTAssertNotNil(harness.pipeline.manualRefreshBlockedUntil())

        // B's first real sample is evaluated with B's own progress.
        bState.clear()
        clock.advance(by: 1_000)
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: true, switched: false, userInitiated: true)
        waitForRequestCount(3)
        settle(coordinator, harness)
        notifications.refreshPermission()
        XCTAssertEqual(notificationClient.deliveries.count, 1, "account B's real low quota alerts normally")
    }
    func testLowQuotaNotifiesOnceAndRepeatedReadsDoNotRepeatIt() throws {
        let current = try useClaudeOfficialProvider()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        DelayedBalanceURLProtocol.setHandler { _ in .init(data: Self.claudeLowUsage, statusCode: 200) }
        let official = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "token"), now: { clock.now })
        let harness = try makeClaudeHarness(official: official, clock: clock)
        let (notifications, notificationClient, enableNotifications) = notificationHarness(providerID: current.id)
        enableNotifications()
        var actions = claudeActions { _ in }
        wire(&actions, to: notifications)
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: actions, claudeQuota: harness.pipeline, now: { clock.now })

        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        waitForRequestCount(1)
        settle(coordinator, harness)
        notifications.refreshPermission()
        XCTAssertEqual(notificationClient.deliveries.count, 1, "the first low reading alerts once")

        for round in 2...3 {
            clock.advance(by: 360)
            coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
            waitForRequestCount(round)
            settle(coordinator, harness)
            notifications.refreshPermission()
        }
        XCTAssertEqual(notificationClient.deliveries.count, 1, "later reads of the same crossing never repeat the alert")
    }

    func testProxyRequiredFailureTextIsShownOnTheCardWithoutCachedData() throws {
        let current = try useClaudeOfficialProvider()
        DelayedBalanceURLProtocol.setHandler { _ in .transportFailure() }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let official = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: "token"), now: { clock.now })
        let harness = try makeClaudeHarness(official: official, clock: clock)
        let rendered = expectation(description: "proxy hint rendered")
        let coordinator = makeCoordinator(repository: repository, officialQuotaClient: official,
            actions: claudeActions { snapshot in
                guard snapshot.kind == .error else { return }
                XCTAssertTrue(snapshot.message?.contains("Possible proxy required") == true, snapshot.message ?? "")
                rendered.fulfill()
            }, claudeQuota: harness.pipeline, now: { clock.now })
        coordinator.refreshStandardProvider(current: current, client: .claude, forceBalance: false, switched: false)
        wait(for: [rendered], timeout: 3)
    }
}
