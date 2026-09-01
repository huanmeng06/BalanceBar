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
            isOpenCodexConfirmed: { _ in false }
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
            isOpenCodexConfirmed: { _ in false }
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
            isOpenCodexConfirmed: { _ in false }
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

    func parse(
        data: Data,
        client: AssistantClient
    ) throws -> OfficialQuotaResponseParser.Output {
        OfficialQuotaResponseParser.Output(windows: windows)
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
