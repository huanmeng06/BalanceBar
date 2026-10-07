import Foundation
import SQLite3
import XCTest
@testable import BalanceBar

final class ProviderRefreshCoordinatorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!
    private var repository: CCSwitchRepository!
    private var session: URLSession!

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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedBalanceURLProtocol.self]
        session = URLSession(configuration: configuration)
        DelayedBalanceURLProtocol.reset()
    }

    override func tearDown() {
        session?.invalidateAndCancel()
        session = nil
        DelayedBalanceURLProtocol.reset()
        repository = nil
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        super.tearDown()
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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
        let coordinator = ProviderRefreshCoordinator(
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

    func testColdStartCreditFailuresPersistQuotaEvidenceUntilSignalCanBeFetched() throws {
        let fixture = ObservationFixture()
        fixture.update { $0.hasBankedReset = false; $0.needsCreditList = true }
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
        clock.advance(by: 180)
        fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
        XCTAssertNil(try observationRefresh(coordinator, fixture: fixture).resetForecast.officialSignal)
        clock.advance(by: 421)
        fixture.update { $0.forecast = ObservationFixture.forecast(episode: "first", publishedAt: published) }
        XCTAssertTrue(try observationRefresh(coordinator, fixture: fixture, renders: 2).resetForecast.isOfficialResetConfirmed)
        XCTAssertEqual(fixture.forecastRequestCount, 2)
    }

    func testNewSignalAdoptsOnlyQuotaEvidenceObservedAfterItsPublication() throws {
        for publicationOffset in [60.0, 240.0] {
            let fixture = ObservationFixture()
            let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
            let store = try observationStore()
            let coordinator = try observationCoordinator(fixture, store: store, clock: clock)
            _ = try observationRefresh(coordinator, fixture: fixture, renders: 2)
            let published = clock.now.addingTimeInterval(publicationOffset)
            clock.advance(by: 180)
            fixture.update { $0.windows = ObservationFixture.windows(100, 100, cycle: 2) }
            _ = try observationRefresh(coordinator, fixture: fixture)
            clock.advance(by: 421)
            fixture.update { $0.forecast = ObservationFixture.forecast(episode: "second", publishedAt: published) }
            let result = try observationRefresh(coordinator, fixture: fixture, renders: 2)
            XCTAssertEqual(result.resetForecast.isOfficialResetConfirmed, publicationOffset < 180)
            XCTAssertEqual(store.load(providerID: "codex-replacement", accountKey: "a@example.com")?.episodeKey, "tweet_id:second")
        }
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
        return ProviderRefreshCoordinator(
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
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    settings_config TEXT NOT NULL,
                    meta TEXT NOT NULL,
                    category TEXT,
                    website_url TEXT,
                    app_type TEXT NOT NULL,
                    is_current INTEGER NOT NULL,
                    sort_index INTEGER,
                    created_at INTEGER NOT NULL
                );
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
            throw fixtureError("fixture SQL failed; sqlite code=\(code); error=\(message)")
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

    func codexAccessToken() -> String? { codexToken }
    func codexAccountProfile() -> CodexAccountProfile? { nil }
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

private final class DelayedBalanceURLProtocol: URLProtocol {
    struct Reply {
        let data: Data
        let statusCode: Int
        let delayUntil: DispatchSemaphore?

        init(data: Data, statusCode: Int, delayUntil: DispatchSemaphore? = nil) {
            self.data = data
            self.statusCode = statusCode
            self.delayUntil = delayUntil
        }
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var recordedRequestCount = 0

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
        Self.lock.lock()
        Self.recordedRequestCount += 1
        let handler = Self.handler
        Self.lock.unlock()

        let reply = handler?(request) ?? Self.success(amount: "0")

        if let gate = reply.delayUntil {
            DispatchQueue.global().async {
                gate.wait()
                self.deliver(reply)
            }
        } else {
            deliver(reply)
        }
    }

    private func deliver(_ reply: Reply) {
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

    override func stopLoading() {}
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
        if let gate = state.quotaGate { gate.0.signal(); gate.1.wait() }
        let windows: [[String: Any]] = state.windows.map {
            var value: [String: Any] = ["kind": $0.kind.rawValue, "remaining": $0.remaining, "label": $0.label]
            value["duration"] = $0.durationSeconds
            value["resetAt"] = $0.resetAt?.timeIntervalSince1970
            return value
        }
        let data = try! JSONSerialization.data(withJSONObject: ["windows": windows, "needsCreditList": state.needsCreditList, "hasBankedReset": state.hasBankedReset])
        return .init(data: data, statusCode: state.quotaStatus)
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
