import Foundation
import SQLite3
import XCTest
@testable import BalanceBar

final class CCSwitchRepositoryTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!
    private var appSettingsURL: URL!
    private var repository: CCSwitchRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-CCSwitchRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        databaseURL = temporaryDirectoryURL.appendingPathComponent("cc-switch.db")
        appSettingsURL = temporaryDirectoryURL.appendingPathComponent("settings.json")
        try createFixtureDatabase()
        repository = CCSwitchRepository(
            databaseURL: databaseURL,
            appSettingsURL: appSettingsURL,
            homeDirectoryURL: temporaryDirectoryURL
        )
    }

    override func tearDownWithError() throws {
        repository = nil
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    func testReadsCurrentProviderChoicesAndSummarySourcesFromFixture() throws {
        XCTAssertNotEqual(
            repository.databaseURL.standardizedFileURL.path,
            CCSwitchRepository.defaultDatabaseURL.standardizedFileURL.path
        )

        let current = try XCTUnwrap(repository.loadCurrent(appType: "codex"))
        XCTAssertEqual(current.id, "codex-custom")
        XCTAssertEqual(current.name, "Fixture Custom")
        XCTAssertFalse(current.isOfficial)
        XCTAssertEqual(current.query?.url, "https://provider.example/usage")
        XCTAssertEqual(current.query?.apiKey, "fixture-key")

        let choices = repository.loadChoices(appType: "codex")
        XCTAssertEqual(choices.map(\.id), ["codex-custom", "codex-official"])
        XCTAssertEqual(choices.map(\.isCurrent), [true, false])

        let summaries = repository.loadSummarySources(appType: "codex")
        XCTAssertEqual(summaries.map(\.id), ["codex-custom", "codex-official"])
        XCTAssertEqual(summaries.first?.query?.url, "https://provider.example/usage")
        XCTAssertNil(summaries.last?.query)
        XCTAssertTrue(summaries.last?.isOfficial == true)
        XCTAssertNil(summaries.last?.officialAccessToken)
    }

    func testSwitchCurrentCommitsFixtureAndWritesOnlyInjectedSettingsPath() throws {
        try repository.switchCurrent(to: "codex-official", appType: "codex")

        XCTAssertEqual(try currentValue(for: "codex-custom"), 0)
        XCTAssertEqual(try currentValue(for: "codex-official"), 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryDirectoryURL.appendingPathComponent(".codex").path
        ))

        let settingsData = try XCTUnwrap(Data(contentsOf: appSettingsURL))
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
        )
        XCTAssertEqual(settings["currentProviderCodex"] as? String, "codex-official")
    }

    func testSwitchCurrentRollsBackWhenActivationWriteFails() throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                CREATE TRIGGER reject_fixture_activation
                BEFORE UPDATE OF is_current ON providers
                WHEN NEW.is_current = 1
                BEGIN
                    SELECT RAISE(ABORT, 'fixture activation rejected');
                END;
                """
            )
        }

        XCTAssertThrowsError(
            try repository.switchCurrent(to: "codex-official", appType: "codex")
        )
        XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
        XCTAssertEqual(try currentValue(for: "codex-official"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
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
                CREATE TABLE proxy_config (
                    app_type TEXT,
                    live_takeover_active INTEGER,
                    enabled INTEGER
                );
                CREATE TABLE proxy_live_backup (app_type TEXT);
                INSERT INTO proxy_config VALUES ('codex', 0, 1);
                INSERT INTO providers VALUES (
                    'codex-custom',
                    'Fixture Custom',
                    '{"api_key":"fixture-key","base_url":"https://provider.example"}',
                    '{"usage_script":{"enabled":true,"accessToken":"fixture-key","baseUrl":"https://provider.example","code":"url: `{{baseUrl}}/usage`"}}',
                    'custom',
                    'https://provider.example',
                    'codex',
                    1,
                    1,
                    1
                );
                INSERT INTO providers VALUES (
                    'codex-official',
                    'Fixture Official',
                    '{}',
                    '{}',
                    'official',
                    NULL,
                    'codex',
                    0,
                    2,
                    2
                );
                INSERT INTO providers VALUES (
                    'claude-other',
                    'Other App',
                    '{}',
                    '{}',
                    'official',
                    NULL,
                    'claude',
                    1,
                    1,
                    1
                );
                """
            )
        }
    }

    private func currentValue(for providerID: String) throws -> Int32 {
        try withDatabase { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT is_current FROM providers WHERE id = ?"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw fixtureError("failed to prepare current provider query")
            }
            sqlite3_bind_text(statement, 1, providerID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw fixtureError("provider row was not found")
            }
            return sqlite3_column_int(statement, 0)
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
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
        }
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            throw fixtureError("fixture SQL failed; sqlite code=\(code); error=\(message)")
        }
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "BalanceBar.CCSwitchRepositoryTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}

extension CCSwitchRepositoryTests {
    private func aggregationState(mode: String = "proxy", attached: Bool = true, enabled: Bool = true,
                                  route: String = "codex-official", members: [String] = [], pending: Bool = false) throws -> Data {
        var codex: [String: Any] = ["mode": mode, "attached": attached, "proxy_route": route,
                                   "stack": ["enabled": enabled, "members": members, "keys": ["ccs-old": "deleted"]]]
        if pending { codex["pending"] = ["op": "stack"] }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "apps": ["codex": codex], "ignored": ["fixture_secret": "not_logged"]])
    }

    private func aggregationReader(_ data: Data, running: Bool = true) -> CCSwitchAggregationRepository {
        CCSwitchAggregationRepository(repository: repository,
            stateURL: temporaryDirectoryURL.appendingPathComponent("live-state.json"),
            isRunning: { running }, read: { _ in data })
    }

    func testAggregationRequiresProxyAttachedEnabledAndRunning() throws {
        for data in [try aggregationState(mode: "direct"), try aggregationState(attached: false),
                     try aggregationState(enabled: false)] {
            guard case .inactive = aggregationReader(data).load() else { return XCTFail("inactive mode must fall back") }
        }
        guard case .untrusted = aggregationReader(try aggregationState(), running: false).load() else {
            return XCTFail("a stale attached flag cannot prove a running aggregation")
        }
        for data in [Data("broken".utf8), try aggregationState(pending: true), try aggregationState(route: "deleted")] {
            guard case .untrusted = aggregationReader(data).load() else { return XCTFail("unsafe state must fall back") }
        }
    }

    func testAggregationDefaultFirstStableDedupAndOfficialOnlyDefault() throws {
        let data = try aggregationState(route: "codex-custom",
            members: ["deleted", "codex-custom", "codex-official", "claude-other", "codex-custom"])
        guard case .active(let entries) = aggregationReader(data).load() else { return XCTFail("valid default") }
        XCTAssertEqual(entries.map(\.providerID), ["codex-custom"])
        XCTAssertEqual(entries.first?.role, .default)
        // The keys registry above contains a deleted ID and must never become a member.
        XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
    }

    func testAggregationZeroOneFourAndSixMembersKeepOrderAndSameNames() throws {
        try withDatabase { db in
            for i in 0..<6 {
                try execute(db, sql: "INSERT INTO providers SELECT 'member-\(i)', 'tokenshop', settings_config, meta, category, website_url, app_type, 0, 10, 10 FROM providers WHERE id='codex-custom'")
            }
        }
        for count in [0, 1, 4, 6] {
            let members = (0..<count).reversed().map { "member-\($0)" }
            guard case .active(let entries) = aggregationReader(try aggregationState(members: members + members)).load() else {
                return XCTFail("valid aggregation")
            }
            XCTAssertEqual(entries.map(\.providerID), ["codex-official"] + members)
            XCTAssertEqual(entries.count, count + 1)
            XCTAssertTrue(entries.dropFirst().allSatisfy { $0.source.name == "tokenshop" && $0.role == .member })
        }
    }

    func testAggregationReadRetriesOnlyOnceAndNeverMixesSwitchingState() throws {
        let a = try aggregationState(route: "codex-official")
        let b = try aggregationState(route: "codex-custom")
        var reads = 0
        let reader = CCSwitchAggregationRepository(repository: repository, isRunning: { true }, read: { _ in
            reads += 1
            return reads.isMultiple(of: 2) ? b : a
        })
        guard case .untrusted = reader.load() else { return XCTFail("mixed state must not publish") }
        XCTAssertEqual(reads, 4)
    }

    func testAggregationDatabaseBusyAndReadFailureAreNotEmptySuccess() throws {
        try withDatabase { db in
            try execute(db, sql: "BEGIN EXCLUSIVE")
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            guard case .untrusted = aggregationReader(try aggregationState()).load() else { return XCTFail("SQL busy") }
        }
        let reader = CCSwitchAggregationRepository(repository: repository, read: { _ in throw CocoaError(.fileReadNoPermission) })
        guard case .untrusted = reader.load() else { return XCTFail("unreadable") }
        XCTAssertTrue(reader.blocksQuickSwitch())
    }

    func testAggregationQuickSwitchGuardAllowsLegacyAndOrdinaryModes() throws {
        let missing = CCSwitchAggregationRepository(repository: repository, read: { _ in throw CocoaError(.fileReadNoSuchFile) })
        XCTAssertFalse(missing.blocksQuickSwitch())
        XCTAssertFalse(aggregationReader(try aggregationState(mode: "direct")).blocksQuickSwitch())
        XCTAssertFalse(aggregationReader(try aggregationState(enabled: false)).blocksQuickSwitch())
        XCTAssertTrue(aggregationReader(try aggregationState()).blocksQuickSwitch())
        XCTAssertTrue(aggregationReader(Data("broken".utf8)).blocksQuickSwitch())
    }

    func testAggregationQuickSwitchBlockedBeforeAnyDatabaseMutation() throws {
        let failed = expectation(description: "aggregation switch explicitly refused")
        let reader = aggregationReader(try aggregationState())
        let coordinator = ProviderSwitchCoordinator(repository: repository, aggregationRepository: reader,
            actions: ProviderSwitchActions(changed: { XCTFail("must never claim a successful switch") }, failed: { message in
                XCTAssertEqual(message, tr(.keyAggregationManageInCCSwitch))
                failed.fulfill()
            }))
        coordinator.switchProvider(providerID: "codex-official", appType: "codex", providerName: "Fixture")
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
        XCTAssertEqual(try currentValue(for: "codex-official"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
    }

    func testAggregationWatcherSurvivesAtomicStateReplacementAndStops() throws {
        let stateURL = temporaryDirectoryURL.appendingPathComponent("live-state.json")
        try aggregationState().write(to: stateURL)
        let changed = DispatchSemaphore(value: 0)
        let watcher = CCSwitchDatabaseWatcher(databaseURL: databaseURL, stateURL: stateURL, onChange: { changed.signal() })
        watcher.start(); watcher.start()
        XCTAssertEqual(watcher.startCount, 1)
        try aggregationState(route: "codex-custom").write(to: stateURL, options: .atomic)
        XCTAssertEqual(changed.wait(timeout: .now() + 2), .success)
        // The replacement inode must be watched again.
        try aggregationState(attached: false).write(to: stateURL)
        XCTAssertEqual(changed.wait(timeout: .now() + 2), .success)
        watcher.stop(); watcher.stop()
        while changed.wait(timeout: .now()) == .success {}
        try aggregationState().write(to: stateURL, options: .atomic)
        XCTAssertEqual(changed.wait(timeout: .now() + 0.2), .timedOut)
    }
}

extension CCSwitchRepositoryTests {
    func testAggregationConfigurationIdentityChangesWhenProviderIDIsRecreated() throws {
        let before = try XCTUnwrap(repository.loadSummarySourcesChecked(appType: "codex", providerIDs: ["codex-custom"]).first)
        try withDatabase { db in
            try execute(db, sql: "CREATE TEMP TABLE saved_provider AS SELECT * FROM providers WHERE id='codex-custom'; DELETE FROM providers WHERE id='codex-custom'; UPDATE saved_provider SET created_at=created_at+1; INSERT INTO providers SELECT * FROM saved_provider;")
        }
        let after = try XCTUnwrap(repository.loadSummarySourcesChecked(appType: "codex", providerIDs: ["codex-custom"]).first)
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(before.name, after.name)
        XCTAssertEqual(before.query?.url, after.query?.url)
        XCTAssertNotEqual(before.configurationRevision, after.configurationRevision)
    }
}


extension CCSwitchRepositoryTests {
    func testCheckedReadsDistinguishLockedDatabaseFromMissingCurrentProvider() throws {
        try withDatabase { db in
            try execute(db, sql: "BEGIN EXCLUSIVE")
            defer { try? execute(db, sql: "ROLLBACK") }
            XCTAssertThrowsError(try repository.loadCurrentChecked(appType: "codex")) { error in
                guard case CCSwitchReadError.sqlite(SQLITE_BUSY) = error else { return XCTFail("expected busy") }
            }
            XCTAssertThrowsError(try repository.loadChoicesChecked(appType: "codex"))
        }
        XCTAssertEqual(try repository.loadCurrentChecked(appType: "codex")?.id, "codex-custom")
        XCTAssertNil(try repository.loadCurrentChecked(appType: "missing-app"))
    }

    func testOptionalNotesSupportsOldSchemaAndChangesWithoutInvalidatingRequestIdentity() throws {
        let before = try repository.loadSummarySourcesChecked(appType: "codex")
        XCTAssertTrue(before.allSatisfy { $0.notes == nil })
        try withDatabase { db in
            try execute(db, sql: "ALTER TABLE providers ADD COLUMN notes TEXT")
            try execute(db, sql: "UPDATE providers SET notes='  Fixture note  ' WHERE id='codex-custom'")
        }
        let after = try repository.loadSummarySourcesChecked(appType: "codex")
        XCTAssertEqual(after.first?.notes, "Fixture note")
        XCTAssertEqual(after.first?.configurationRevision, before.first?.configurationRevision)
        XCTAssertNil(after.last?.notes)
    }
}


extension CCSwitchRepositoryTests {
    func testBusyDatabasePreventsQuickSwitchBeforeSettingsOrProviderMutation() throws {
        let reader = aggregationReader(try aggregationState(mode: "direct"))
        let failed = expectation(description: "busy switch fails before process or config side effects")
        let coordinator = ProviderSwitchCoordinator(repository: repository, aggregationRepository: reader,
            actions: ProviderSwitchActions(changed: { XCTFail("busy read must not switch") }, failed: { message in
                XCTAssertEqual(message, tr(.keyCCSwitchRepositoryUnableToOpenTheCcSwitchDatabase))
                failed.fulfill()
            }))
        try withDatabase { db in
            try execute(db, sql: "BEGIN EXCLUSIVE")
            defer { try? execute(db, sql: "ROLLBACK") }
            coordinator.switchProvider(providerID: "codex-official", appType: "codex", providerName: "Fixture")
            wait(for: [failed], timeout: 2)
        }
        XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
    }
}


extension CCSwitchRepositoryTests {
    func testAggregationNoteOrderReloadsDatabaseSortWithoutChangingRegisteredMembers() throws {
        try withDatabase { db in
            try execute(db, sql: "ALTER TABLE providers ADD COLUMN notes TEXT")
            try execute(db, sql: "UPDATE providers SET notes='Grok' WHERE id='codex-custom'")
            try execute(db, sql: """
                INSERT INTO providers SELECT 'peer', name, settings_config, meta, category, website_url,
                    app_type, 0, 3, 3, 'GPT' FROM providers WHERE id='codex-custom'
                """)
        }
        let reader = aggregationReader(try aggregationState(members: ["codex-custom", "peer"]))
        func displays() throws -> [AggregatedProviderDisplay] {
            guard case .active(let entries) = reader.load() else { throw NSError(domain: "Fixture", code: 1) }
            XCTAssertEqual(entries.map(\.providerID), ["codex-official", "codex-custom", "peer"])
            let date = Date(timeIntervalSince1970: 100)
            return entries.map { entry in
                .init(entry: entry, identity: .init(providerID: entry.providerID, accountScope: entry.providerID,
                    configurationRevision: "fixture"), snapshot: entry.source.isOfficial
                    ? .official(entry.source.name, 90, "quota", nil, date)
                    : .balance(entry.source.name, 3.73, "USD", nil, date), account: nil, status: .fresh,
                    reason: nil, fetchedAt: date)
            }
        }
        let before = try displays()
        XCTAssertEqual(AggregationWalletPresentation.cards(before).last?.groupedNotes, ["Grok", "GPT"])
        try withDatabase { db in try execute(db, sql: "UPDATE providers SET sort_index=0 WHERE id='peer'") }
        let after = try displays()
        XCTAssertNotEqual(before, after, "display order must invalidate semantic publication even with unchanged IDs/data")
        XCTAssertEqual(AggregationWalletPresentation.cards(after).last?.groupedNotes, ["GPT", "Grok"])
        XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
    }
}
