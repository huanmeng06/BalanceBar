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
            updateQuickSwitchSummary: { _, _ in },
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
            updateQuickSwitchSummary: { _, _ in callbackCompleted.fulfill() },
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

private final class DelayedBalanceURLProtocol: URLProtocol {
    struct Reply {
        let data: Data
        let statusCode: Int
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    static func setHandler(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock()
        self.handler = handler
        lock.unlock()
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
        let reply = Self.handler?(request) ?? Self.success(amount: "0")
        Self.lock.unlock()

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
