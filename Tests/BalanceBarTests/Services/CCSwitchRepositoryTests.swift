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
