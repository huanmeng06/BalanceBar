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
        let codex = temporaryDirectoryURL.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data("model_provider = \"custom\"\n[model_providers.custom]\nbase_url = \"https://provider.example\"\n".utf8).write(to: codex.appendingPathComponent("config.toml"))
        try Data(#"{"OPENAI_API_KEY":"fixture-key"}"#.utf8).write(to: codex.appendingPathComponent("auth.json"))
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET settings_config = '{\"auth\":{},\"config\":\"\"}' WHERE id = 'codex-official'")
        }
        repository = CCSwitchRepository(
            databaseURL: databaseURL,
            appSettingsURL: appSettingsURL,
            homeDirectoryURL: temporaryDirectoryURL
        )
        try writeDeviceMode("direct")
    }

    override func tearDownWithError() throws {
        repository = nil
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    func testOfficialDefaultWithoutConfigCanSwitchButCustomAndMalformedConfigCannot() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent(".codex/config.toml")
        try FileManager.default.removeItem(at: configURL)
        XCTAssertEqual(repository.quickSwitchSafety(), .blockedUntrusted, "custom route needs its configuration")
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET is_current = CASE WHEN id = 'codex-official' THEN 1 ELSE 0 END WHERE app_type = 'codex'")
        }
        try Data(#"{"tokens":{"access_token":"fixture-login"}}"#.utf8).write(to: temporaryDirectoryURL.appendingPathComponent(".codex/auth.json"))
        XCTAssertEqual(repository.quickSwitchSafety(), .allowedDirect)
        try Data([0xff]).write(to: configURL)
        XCTAssertEqual(repository.quickSwitchSafety(), .blockedUntrusted, "corrupt is different from absent")
        try FileManager.default.removeItem(at: configURL)
        try writeDeviceMode("proxy")
        XCTAssertEqual(repository.quickSwitchSafety(), .blockedRouting)
        try writeDeviceMode("direct")
        try withDatabase { db in
            try execute(db, sql: #"UPDATE providers SET settings_config = '{"auth":{"OPENAI_API_KEY":"fixture-key"},"config":"model_provider = \"custom\"\n[model_providers.custom]\nbase_url = \"https://provider.example\"\n"}' WHERE id = 'codex-custom'"#)
        }
        try repository.switchCurrent(to: "codex-custom", appType: "codex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
    }

    private func prepareClaudeDirect() throws -> URL {
        let url = temporaryDirectoryURL.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://claude.example","ANTHROPIC_AUTH_TOKEN":"fixture"},"theme":"dark"}"#.utf8).write(to: url)
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET settings_config = '{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://claude.example\",\"ANTHROPIC_AUTH_TOKEN\":\"fixture\"}}' WHERE id = 'claude-other'")
            try execute(db, sql: "INSERT INTO providers SELECT 'claude-target', 'Target', '{}', '{}', 'official', NULL, 'claude', 0, 2, 2 WHERE NOT EXISTS (SELECT 1 FROM providers WHERE id = 'claude-target')")
        }
        try writeClaudeMode("direct")
        return url
    }

    private func writeClaudeMode(_ mode: String) throws {
        try JSONSerialization.data(withJSONObject: ["version": 1, "apps": ["codex": ["mode": "direct"], "claude": ["mode": mode]]])
            .write(to: repository.deviceStateURL, options: .atomic)
    }

    func testClaudeUsesOwnModeHistoryConfigurationAndWriteGuard() throws {
        let url = try prepareClaudeDirect()
        let original = try Data(contentsOf: url)
        XCTAssertEqual(repository.quickSwitchSafety(appType: "claude"), .allowedDirect)
        try writeClaudeMode("proxy")
        XCTAssertEqual(repository.quickSwitchSafety(appType: "claude"), .blockedRouting)
        XCTAssertEqual(repository.quickSwitchSafety(), .allowedDirect, "Claude history must not lock Codex")
        XCTAssertThrowsError(try repository.switchCurrent(to: "claude-target", appType: "claude"))
        try FileManager.default.removeItem(at: repository.deviceStateURL)
        let restarted = CCSwitchRepository(databaseURL: databaseURL, appSettingsURL: appSettingsURL, homeDirectoryURL: temporaryDirectoryURL)
        XCTAssertEqual(restarted.quickSwitchSafety(appType: "claude"), .blockedUntrusted)
        try writeClaudeMode("direct")
        XCTAssertEqual(repository.quickSwitchSafety(appType: "claude"), .allowedDirect)
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://wrong.example"}}"#.utf8).write(to: url)
        XCTAssertEqual(repository.quickSwitchSafety(appType: "claude"), .blockedUntrusted)
        try original.write(to: url)
        for stage in ["beforePublish", "beforePointer"] {
            try writeClaudeMode("direct")
            repository.switchWriteObserver = { point in if point == stage { try! self.writeClaudeMode("proxy") } }
            XCTAssertThrowsError(try repository.switchCurrent(to: "claude-target", appType: "claude"))
            XCTAssertEqual(try currentValue(for: "claude-other"), 1)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        repository.switchWriteObserver = nil
        try writeClaudeMode("direct")
        try repository.switchCurrent(to: "claude-target", appType: "claude")
        XCTAssertEqual(try currentValue(for: "claude-target"), 1)
    }

    func testClaudeSwitchReplacesOnlyProviderEnvironmentAndPreservesIndependentSettings() throws {
        let url = try prepareClaudeDirect()
        var original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        original["permissions"] = ["allow": ["Read"], "deny": ["Bash(rm:*)"]]
        original["hooks"] = ["SessionStart": [["hooks": [["type": "command", "command": "echo fixture"]]]]]
        original["mcpServers"] = ["fixture": ["command": "fixture-cli", "args": ["--local"]]]
        original["futureUserSetting"] = ["enabled": true, "values": [1, 2, 3]]
        try JSONSerialization.data(withJSONObject: original).write(to: url)
        let originalIndependent = original.filter { $0.key != "env" } as NSDictionary
        let nextEnv = ["ANTHROPIC_BASE_URL": "https://next.example", "CLAUDE_CODE_OAUTH_TOKEN": "fixture-next"]
        let target: [String: Any] = ["env": nextEnv, "theme": "light", "permissions": ["allow": ["Bash(*)"]]]
        let targetText = String(decoding: try JSONSerialization.data(withJSONObject: target), as: UTF8.self)
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET settings_config='\(targetText)' WHERE id='claude-target'")
        }
        let originalBytes = try Data(contentsOf: url)
        repository.switchWriteObserver = { stage in
            if stage == "beforePointer" { try! self.writeClaudeMode("proxy") }
        }
        XCTAssertThrowsError(try repository.switchCurrent(to: "claude-target", appType: "claude"))
        XCTAssertEqual(try Data(contentsOf: url), originalBytes, "rollback preserves the whole original document")
        repository.switchWriteObserver = nil
        try writeClaudeMode("direct")
        try repository.switchCurrent(to: "claude-target", appType: "claude")
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(actual["env"] as? [String: String], nextEnv, "no stale auth or proxy environment survives")
        XCTAssertEqual(actual.filter { $0.key != "env" } as NSDictionary, originalIndependent)
        XCTAssertEqual(repository.quickSwitchSafety(appType: "claude"), .allowedDirect)
        // Return to an official/default Provider without env; independent settings remain intact.
        try withDatabase { db in try execute(db, sql: "UPDATE providers SET settings_config='{}' WHERE id='claude-other'") }
        try repository.switchCurrent(to: "claude-other", appType: "claude")
        let official = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(official["env"])
        XCTAssertEqual(official as NSDictionary, originalIndependent)
    }

    func testClaudeProxyOAuthAndUnknownEnvironmentDifferencesBlockDirectSwitching() throws {
        let url = try prepareClaudeDirect()
        let original = try Data(contentsOf: url)
        for variable in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy",
                         "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "NODE_EXTRA_CA_CERTS",
                         "NEW_UNRECOGNIZED_AUTH_SETTING"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var env = try XCTUnwrap(object["env"] as? [String: String])
            env[variable] = "fixture-override"
            object["env"] = env
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            let changed = try Data(contentsOf: url)
            XCTAssertEqual(repository.quickSwitchSafety(appType: "claude"), .blockedUntrusted, variable)
            XCTAssertThrowsError(try repository.switchCurrent(to: "claude-target", appType: "claude"), variable)
            XCTAssertEqual(try currentValue(for: "claude-other"), 1)
            XCTAssertEqual(try Data(contentsOf: url), changed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
        }
        try original.write(to: url)
        XCTAssertEqual(repository.quickSwitchSafety(appType: "claude"), .allowedDirect)
        try withDatabase { db in
            try execute(db, sql: #"UPDATE providers SET settings_config = '{"env":{"ANTHROPIC_BASE_URL":"https://claude.example","ANTHROPIC_AUTH_TOKEN":"fixture","HTTPS_PROXY":"fixture-matched","CLAUDE_CODE_OAUTH_TOKEN":"fixture-oauth"}}' WHERE id = 'claude-other'"#)
        }
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://claude.example","ANTHROPIC_AUTH_TOKEN":"fixture","HTTPS_PROXY":"fixture-matched","CLAUDE_CODE_OAUTH_TOKEN":"fixture-oauth"},"theme":"light"}"#.utf8).write(to: url)
        XCTAssertEqual(repository.quickSwitchSafety(appType: "claude"), .allowedDirect, "matched environment and unrelated theme are compatible")
    }

    func testClaudeProxyBeforeAndDuringTerminationNeverWrites() throws {
        for phase in ["initial", "beforeTerminate", "duringTerminate"] {
            let url = try prepareClaudeDirect()
            let original = try Data(contentsOf: url)
            var terminated = false
            var stops = 0
            var restores = 0
            let finished = expectation(description: phase)
            if phase == "initial" { try writeClaudeMode("proxy") }
            let instance = ProviderSwitchRuntime.Instance(applicationURL: URL(fileURLWithPath: "/fixture/CCSwitch.app"), terminate: {
                stops += 1
                terminated = true
                try! self.writeClaudeMode("proxy")
                return true
            }, isTerminated: { terminated })
            let runtime = ProviderSwitchRuntime(running: {
                if terminated { return nil }
                if phase == "beforeTerminate" { try! self.writeClaudeMode("proxy") }
                return instance
            }, reopen: { _ in restores += 1 })
            let queue = DispatchQueue(label: "fixture.claude.boundary")
            let coordinator = ProviderSwitchCoordinator(repository: repository, queue: queue, runtime: runtime,
                actions: .init(changed: { XCTFail("unsafe switch") }, failed: { _ in finished.fulfill() }))
            coordinator.switchProvider(providerID: "claude-target", appType: "claude", providerName: "fixture")
            wait(for: [finished], timeout: 3)
            queue.sync {}
            XCTAssertEqual(stops, phase == "duringTerminate" ? 1 : 0)
            XCTAssertEqual(restores, stops)
            XCTAssertEqual(try currentValue(for: "claude-other"), 1)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testRealHelperProcessTerminationRaceDoesNotPublishConfiguration() throws {
        // A disposable CLI process exercises actual asynchronous process exit, never the user's CCS.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let configURL = temporaryDirectoryURL.appendingPathComponent(".codex/config.toml")
        let original = try Data(contentsOf: configURL)
        var restores = 0
        let finished = expectation(description: "process exit race aborts")
        let runtime = ProviderSwitchRuntime(running: {
            guard process.isRunning else { return nil }
            return .init(applicationURL: URL(fileURLWithPath: "/fixture/CCSwitch.app"), terminate: {
                // Enter proxy after the last validation but before the actual termination signal.
                try! self.writeDeviceMode("proxy")
                process.terminate()
                return true
            }, isTerminated: { !process.isRunning })
        }, reopen: { _ in restores += 1 })
        let queue = DispatchQueue(label: "fixture.real-process.boundary")
        let coordinator = ProviderSwitchCoordinator(repository: repository, queue: queue, runtime: runtime,
            actions: .init(changed: { XCTFail("race must abort") }, failed: { _ in finished.fulfill() }))
        coordinator.switchProvider(providerID: "codex-official", appType: "codex", providerName: "fixture")
        wait(for: [finished], timeout: 6)
        queue.sync {}
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(restores, 1)
        XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
        XCTAssertEqual(try Data(contentsOf: configURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
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

    func testOfficialAPIKeysUseBalanceQueriesForCurrentAndSummary() throws {
        let cases: [(String, String)] = [
            ("codex", #"{"auth":{"OPENAI_API_KEY":"fixture-api-key"}}"#),
            ("claude", #"{"env":{"ANTHROPIC_API_KEY":"fixture-api-key"}}"#),
            ("claude", #"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-api-key"}}"#)
        ]
        for (app, settings) in cases {
            let id = app == "codex" ? "codex-official" : "claude-other"
            try withDatabase { db in
                try execute(db, sql: "UPDATE providers SET is_current = 0 WHERE app_type = '\(app)'")
                try execute(db, sql: """
                    UPDATE providers SET settings_config = '\(settings)',
                    meta = '{"usage_script":{"enabled":true,"baseUrl":"https://api.example","code":"url: `{{baseUrl}}/usage`"}}',
                    is_current = 1 WHERE id = '\(id)'
                    """)
            }
            let current = try XCTUnwrap(repository.loadCurrent(appType: app))
            XCTAssertFalse(current.isOfficial, "\(app): \(settings)")
            XCTAssertEqual(current.query?.apiKey, "fixture-api-key")
            let summary = try XCTUnwrap(repository.loadSummarySources(appType: app).first { $0.id == id })
            XCTAssertFalse(summary.isOfficial)
            XCTAssertEqual(summary.query?.apiKey, "fixture-api-key")
            XCTAssertNil(summary.officialAccessToken)
        }
    }

    func testOfficialAPIWithoutUsageScriptDoesNotFallBackToSubscription() throws {
        try withDatabase { db in
            try execute(db, sql: """
                UPDATE providers SET settings_config = '{"env":{"ANTHROPIC_API_KEY":"fixture-key"}}'
                WHERE id = 'claude-other'
                """)
        }
        let current = try XCTUnwrap(repository.loadCurrent(appType: "claude"))
        XCTAssertFalse(current.isOfficial)
        XCTAssertNil(current.query)
        XCTAssertEqual(current.queryFailure, .usageScriptMissing)
        XCTAssertFalse(try XCTUnwrap(repository.loadSummarySources(appType: "claude").first).isOfficial)
    }

    func testOfficialSubscriptionAndManagedOAuthKeepQuotaIdentity() throws {
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET is_current = CASE WHEN id = 'codex-official' THEN 1 ELSE 0 END WHERE app_type = 'codex'")
            try execute(db, sql: """
                UPDATE providers SET settings_config = '{"auth":{"OPENAI_API_KEY":"  "}}'
                WHERE id = 'codex-official'
                """)
        }
        XCTAssertTrue(try XCTUnwrap(repository.loadCurrent(appType: "codex")).isOfficial)
        XCTAssertTrue(try XCTUnwrap(repository.loadCurrent(appType: "claude")).isOfficial)
        try withDatabase { db in
            try execute(db, sql: """
                UPDATE providers SET settings_config = '{"auth":{"OPENAI_API_KEY":"stale-fixture-key","tokens":{"access_token":"fixture-oauth"}}}',
                meta = '{"authBinding":{"source":"managed_account","authProvider":"codex_oauth","accountId":"fixture-account"}}'
                WHERE id = 'codex-official'
                """)
        }
        XCTAssertTrue(try XCTUnwrap(repository.loadCurrent(appType: "codex")).isOfficial)
        let summary = try XCTUnwrap(repository.loadSummarySources(appType: "codex").first { $0.id == "codex-official" })
        XCTAssertTrue(summary.isOfficial)
        XCTAssertEqual(summary.officialAccessToken, "fixture-oauth")
        XCTAssertNil(summary.query)
    }

    func testSwitchCurrentCommitsFixtureAndWritesOnlyInjectedSettingsPath() throws {
        try repository.switchCurrent(to: "codex-official", appType: "codex")

        XCTAssertEqual(try currentValue(for: "codex-custom"), 0)
        XCTAssertEqual(try currentValue(for: "codex-official"), 1)
        let config = try String(contentsOf: temporaryDirectoryURL.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("model_provider = \"custom\""))
        XCTAssertFalse(config.contains("https://provider.example"))
        XCTAssertEqual(repository.quickSwitchSafety(), .allowedDirect)

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
    private func writeDeviceMode(_ mode: String, stack: Bool = false) throws {
        let url = repository.deviceStateURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = ["version": 1, "apps": ["codex": ["mode": mode, "attached": mode == "proxy", "stack": ["enabled": stack]]]]
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    func testLocalModeOverridesSyncedEnabledAndRequiresMatchingConfiguration() throws {
        XCTAssertEqual(repository.quickSwitchSafety(), .allowedDirect, "synced enabled=1 cannot permanently lock verified direct")
        try withDatabase { db in try execute(db, sql: "UPDATE proxy_config SET enabled = 0, live_takeover_active = 0") }
        XCTAssertEqual(repository.quickSwitchSafety(readState: { _ in throw CocoaError(.fileReadNoSuchFile) }), .allowedLegacyDirect)
        try writeDeviceMode("proxy")
        XCTAssertEqual(repository.quickSwitchSafety(), .blockedRouting)
        try writeDeviceMode("proxy", stack: true)
        XCTAssertEqual(repository.quickSwitchSafety(), .blockedAggregation)
        try writeDeviceMode("direct")
        XCTAssertEqual(repository.quickSwitchSafety(), .allowedDirect)
        try Data("model_provider = \"other\"\n[model_providers.other]\nbase_url = \"https://other.example\"".utf8)
            .write(to: temporaryDirectoryURL.appendingPathComponent(".codex/config.toml"))
        XCTAssertEqual(repository.quickSwitchSafety(), .blockedUntrusted)
    }

    func testChangedTargetRevisionBeforeTerminateAbortsAndLocalMarkerIsNotNegated() throws {
        var terminated = false
        let failed = expectation(description: "revision changed before termination")
        let instance = ProviderSwitchRuntime.Instance(applicationURL: nil, terminate: { terminated = true; return true }, isTerminated: { terminated })
        let runtime = ProviderSwitchRuntime(running: {
            try! self.withDatabase { db in try self.execute(db, sql: "UPDATE providers SET name = 'edited' WHERE id = 'codex-official'") }
            return instance
        }, reopen: { _ in XCTFail("must not reopen an application we did not stop") })
        let queue = DispatchQueue(label: "fixture.switch.revision")
        let coordinator = ProviderSwitchCoordinator(repository: repository, queue: queue, runtime: runtime,
            actions: .init(changed: { XCTFail("must not switch stale target") }, failed: { _ in failed.fulfill() }))
        coordinator.switchProvider(providerID: "codex-official", appType: "codex", providerName: "fixture")
        wait(for: [failed], timeout: 3)
        queue.sync {}
        XCTAssertFalse(terminated)
        XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
        try withDatabase { db in try execute(db, sql: "UPDATE proxy_config SET enabled = 0, live_takeover_active = 1") }
        XCTAssertEqual(repository.proxyTakeoverStatus(appType: "codex"), .active)
        XCTAssertEqual(repository.quickSwitchSafety(), .blockedUntrusted)
    }

    func testIndirectOrQuotedRoutingCannotBeMistakenForDirectEvidence() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent(".codex/config.toml")
        for config in [
            "profile = \"other\"\nmodel_provider = \"custom\"\n[model_providers.custom]\nbase_url = \"https://provider.example\"",
            "model_provider = \"custom\"\nmodel_providers.custom.base_url = \"https://provider.example\"",
            "model_provider = \"custom\"\nmodel_providers = { custom = { base_url = \"https://provider.example\" } }",
            "\"model_provider\" = \"other\"\n[model_providers.other]\nbase_url = \"https://other.example\""
        ] {
            try Data(config.utf8).write(to: configURL)
            XCTAssertEqual(repository.quickSwitchSafety(), .blockedUntrusted)
        }
        let valid = "\"model_provider\" = \"custom\"\n[model_providers.custom]\nbase_url = \"https://provider.example\"\n[mcp_servers.fixture]\ncommand = \"fixture\"\n[[projects.fixture.entries]]\nname = \"unrelated\""
        try Data(valid.utf8).write(to: configURL)
        XCTAssertEqual(repository.quickSwitchSafety(), .allowedDirect, "unrelated MCP/project fields do not decide routing")
    }

    func testRefusedTerminationAndChangedClientNeverWriteOrReopen() throws {
        for clientChanged in [false, true] {
            let failed = expectation(description: "cannot stop this instance")
            var attempts = 0
            let runtime = ProviderSwitchRuntime(running: {
                .init(applicationURL: URL(fileURLWithPath: "/fixture/CCSwitch.app"),
                    terminate: { attempts += 1; return false }, isTerminated: { false })
            }, reopen: { _ in XCTFail("must not reopen an instance we did not stop") })
            let queue = DispatchQueue(label: "fixture.switch.refused")
            let coordinator = ProviderSwitchCoordinator(repository: repository, queue: queue, runtime: runtime,
                isClientCurrent: { _ in !clientChanged },
                actions: .init(changed: { XCTFail("must not write") }, failed: { _ in failed.fulfill() }))
            coordinator.switchProvider(providerID: "codex-official", appType: "codex", providerName: "fixture")
            wait(for: [failed], timeout: 3)
            queue.sync {}
            XCTAssertEqual(attempts, clientChanged ? 0 : 1)
            XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
        }
    }

    func testPreparedWriteCannotOverwriteChangedInputsOrTarget() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent(".codex/config.toml")
        let original = try Data(contentsOf: configURL)
        for changedTarget in [false, true] {
            try original.write(to: configURL)
            repository.switchWriteObserver = { stage in
                guard stage == "afterPrepare" else { return }
                if changedTarget {
                    try! self.withDatabase { db in
                        try self.execute(db, sql: "UPDATE providers SET settings_config = '{\"auth\":{},\"config\":\"model = \\\"changed\\\"\"}' WHERE id = 'codex-official'")
                    }
                } else {
                    var external = original
                    external.append(Data("\n[mcp_servers.new]\ncommand = \"new-tool\"\n".utf8))
                    try! external.write(to: configURL)
                }
            }
            XCTAssertThrowsError(try repository.switchCurrent(to: "codex-official", appType: "codex"))
            XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
            let result = try Data(contentsOf: configURL)
            XCTAssertEqual(result == original, changedTarget)
            XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
        }
        repository.switchWriteObserver = nil
    }

    func testUnparseableOrPendingStateNeverAuthorizesDirectWrite() throws {
        for state in ["broken", #"{"version":99,"apps":{}}"#, #"{"version":true,"apps":{"codex":{"mode":"direct"}}}"#, #"{"apps":{"codex":{"mode":"direct","pending":{}}}}"#] {
            XCTAssertEqual(repository.quickSwitchSafety(readState: { _ in Data(state.utf8) }), .blockedUntrusted)
        }
        try withDatabase { db in
            try execute(db, sql: "BEGIN EXCLUSIVE")
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            XCTAssertEqual(repository.quickSwitchSafety(), .blockedUntrusted)
        }
    }

    func testProxyBeforeTerminateOrAfterTerminateAbortsWithoutWrites() throws {
        for enterBeforeTerminate in [true, false] {
            try writeDeviceMode("direct")
            let original = try Data(contentsOf: temporaryDirectoryURL.appendingPathComponent(".codex/config.toml"))
            var terminateCount = 0
            var reopenCount = 0
            var terminated = false
            var firstLookup = true
            let finished = expectation(description: "unsafe transition rejected")
            let instance = ProviderSwitchRuntime.Instance(applicationURL: URL(fileURLWithPath: "/fixture/CCSwitch.app"),
                terminate: {
                    terminateCount += 1
                    terminated = true
                    try! self.writeDeviceMode("proxy", stack: true)
                    return true
                }, isTerminated: { terminated })
            let runtime = ProviderSwitchRuntime(running: {
                if terminated { return nil }
                if firstLookup {
                    firstLookup = false
                    if enterBeforeTerminate { try! self.writeDeviceMode("proxy", stack: true) }
                }
                return instance
            }, reopen: { _ in reopenCount += 1 })
            let queue = DispatchQueue(label: "fixture.switch.boundary")
            let coordinator = ProviderSwitchCoordinator(repository: repository, queue: queue, runtime: runtime,
                actions: .init(changed: { XCTFail("must not switch") }, failed: { _ in finished.fulfill() }))
            coordinator.switchProvider(providerID: "codex-official", appType: "codex", providerName: "fixture")
            wait(for: [finished], timeout: 3)
            queue.sync {} // Observe completion of restoration after the failure callback.
            XCTAssertEqual(terminateCount, enterBeforeTerminate ? 0 : 1)
            XCTAssertEqual(reopenCount, enterBeforeTerminate ? 0 : 1)
            XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
            XCTAssertEqual(try Data(contentsOf: temporaryDirectoryURL.appendingPathComponent(".codex/config.toml")), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
        }
    }

    func testRepositoryGuardRejectsProxyAndRollsBackPublishedFilesWithoutClobberingOthers() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent(".codex/config.toml")
        let authURL = temporaryDirectoryURL.appendingPathComponent(".codex/auth.json")
        let config = try Data(contentsOf: configURL)
        let auth = try Data(contentsOf: authURL)
        for stage in ["beforePublish", "beforePointer", "externalWriter"] {
            try writeDeviceMode("direct")
            try config.write(to: configURL)
            try auth.write(to: authURL)
            repository.switchWriteObserver = { point in
                if point == stage || (stage == "externalWriter" && point == "beforePointer") {
                    if stage == "externalWriter" { try! Data("external writer".utf8).write(to: configURL) }
                    try! self.writeDeviceMode("proxy", stack: true)
                }
            }
            XCTAssertThrowsError(try repository.switchCurrent(to: "codex-official", appType: "codex"))
            XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
            XCTAssertEqual(try Data(contentsOf: configURL), stage == "externalWriter" ? Data("external writer".utf8) : config)
            XCTAssertEqual(try Data(contentsOf: authURL), auth)
            XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
        }
        repository.switchWriteObserver = nil
    }
}

extension CCSwitchRepositoryTests {
    private func aggregationState(mode: String = "proxy", attached: Bool = true, enabled: Bool = true,
                                  route: String = "codex-official", members: [String] = [], pending: Bool = false) throws -> Data {
        var codex: [String: Any] = ["mode": mode, "attached": attached && mode == "proxy", "proxy_route": route,
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

    func testAggregationPreservesCCSwitchOrderAndOfficialOnlyDefault() throws {
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
            XCTAssertEqual(entries.map(\.providerID), members + ["codex-official"])
            XCTAssertEqual(entries.count, count + 1)
            XCTAssertTrue(entries.filter { $0.role == .member }.allSatisfy { $0.source.name == "tokenshop" })
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

    func testAggregationConfirmedAbsenceClearsTrustedStateAfterWindow() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var payload: Data? = try aggregationState()
        let reader = CCSwitchAggregationRepository(
            repository: repository,
            isRunning: { true },
            read: { _ in
                guard let payload else { throw CocoaError(.fileReadNoSuchFile) }
                return payload
            },
            now: { now }
        )
        guard case .active = reader.load() else { return XCTFail("expected aggregation") }
        XCTAssertTrue(reader.blocksQuickSwitch())
        payload = nil
        guard case .untrusted = reader.load() else { return XCTFail("transient missing stays untrusted") }
        XCTAssertTrue(reader.blocksQuickSwitch())
        now.addTimeInterval(CCSwitchAggregationRepository.confirmedAbsenceInterval)
        guard case .inactive = reader.load() else { return XCTFail("confirmed absence becomes inactive") }
        guard case .inactive = reader.load() else { return XCTFail("confirmed absence must remain inactive") }
        XCTAssertTrue(reader.blocksQuickSwitch(), "absence timeout may hide stale cards but cannot authorize writes")
        payload = try aggregationState(mode: "direct")
        guard case .inactive = reader.load() else { return XCTFail("direct remains inactive") }
        XCTAssertFalse(reader.blocksQuickSwitch(), "a verified direct state is required to release protection")
    }

    func testAggregationQuickSwitchGuardAllowsLegacyAndOrdinaryModes() throws {
        try withDatabase { db in
            try execute(db, sql: "UPDATE proxy_config SET enabled = 0, live_takeover_active = 0 WHERE app_type = 'codex'")
        }
        let missing = CCSwitchAggregationRepository(repository: repository, read: { _ in throw CocoaError(.fileReadNoSuchFile) })
        XCTAssertFalse(missing.blocksQuickSwitch())
        XCTAssertFalse(aggregationReader(try aggregationState(mode: "direct")).blocksQuickSwitch())
        XCTAssertTrue(aggregationReader(try aggregationState(enabled: false)).blocksQuickSwitch(), "routing is also managed by CCS")
        XCTAssertTrue(aggregationReader(try aggregationState()).blocksQuickSwitch())
        XCTAssertTrue(aggregationReader(Data("broken".utf8)).blocksQuickSwitch())
    }

    func testProxyTakeoverEnabledColumnOverridesRetiredField() throws {
        try withDatabase { db in
            try execute(db, sql: "UPDATE proxy_config SET enabled = 1, live_takeover_active = 0 WHERE app_type = 'codex'")
        }
        XCTAssertEqual(repository.proxyTakeoverStatus(appType: "codex"), .active)
        let reader = CCSwitchAggregationRepository(repository: repository, read: { _ in
            throw CocoaError(.fileReadNoSuchFile)
        })
        XCTAssertTrue(reader.blocksQuickSwitch())
    }

    func testMissingCodexStateUsesProxyTakeoverProtection() throws {
        try withDatabase { db in
            try execute(db, sql: "UPDATE proxy_config SET enabled = 1, live_takeover_active = 0 WHERE app_type = 'codex'")
        }
        let reader = CCSwitchAggregationRepository(repository: repository, read: { _ in
            Data(#"{"apps":{}}"#.utf8)
        })
        guard case .untrusted = reader.load() else { return XCTFail("missing apps.codex must remain untrusted") }
        XCTAssertTrue(reader.blocksQuickSwitch())
    }

    func testDatabaseZeroCannotClearKnownProxyProtection() throws {
        var payload: Data? = try aggregationState()
        let reader = CCSwitchAggregationRepository(repository: repository, isRunning: { true }, read: { _ in
            guard let payload else { throw CocoaError(.fileReadNoSuchFile) }
            return payload
        })
        guard case .active = reader.load() else { return XCTFail("fixture active") }
        XCTAssertTrue(reader.blocksQuickSwitch())
        try withDatabase { db in try execute(db, sql: "UPDATE proxy_config SET enabled = 0, live_takeover_active = 0") }
        for absent in [nil, Data(#"{"apps":{}}"#.utf8)] as [Data?] {
            payload = absent
            XCTAssertTrue(reader.blocksQuickSwitch())
        }
        let restarted = CCSwitchRepository(databaseURL: databaseURL, homeDirectoryURL: temporaryDirectoryURL)
        XCTAssertEqual(restarted.quickSwitchSafety(readState: { _ in throw CocoaError(.fileReadNoSuchFile) }), .blockedUntrusted)
        payload = try aggregationState(mode: "direct")
        XCTAssertFalse(reader.blocksQuickSwitch(), "verified local direct and matching live configuration release protection")
        payload = nil
        XCTAssertFalse(reader.blocksQuickSwitch(), "legacy direct evidence is usable after verified exit")
    }

    func testProxyTakeoverSchemaAndBackupCompatibility() throws {
        try withDatabase { db in
            try execute(db, sql: "DROP TABLE proxy_config; DROP TABLE proxy_live_backup")
        }
        XCTAssertEqual(repository.proxyTakeoverStatus(appType: "codex"), .inactive)
        let missing = CCSwitchAggregationRepository(repository: repository, read: { _ in
            throw CocoaError(.fileReadNoSuchFile)
        })
        XCTAssertFalse(missing.blocksQuickSwitch())
        try withDatabase { db in
            try execute(db, sql: "CREATE TABLE proxy_live_backup (app_type TEXT); INSERT INTO proxy_live_backup VALUES ('claude')")
        }
        XCTAssertEqual(repository.proxyTakeoverStatus(appType: "codex"), .inactive)
        try withDatabase { db in
            try execute(db, sql: "INSERT INTO proxy_live_backup VALUES ('codex')")
        }
        XCTAssertEqual(repository.proxyTakeoverStatus(appType: "codex"), .active)
        XCTAssertTrue(missing.blocksQuickSwitch())
        try withDatabase { db in
            try execute(db, sql: "DROP TABLE proxy_live_backup; CREATE TABLE proxy_config (app_type TEXT, live_takeover_active INTEGER); INSERT INTO proxy_config VALUES ('codex', 1)")
        }
        XCTAssertEqual(repository.proxyTakeoverStatus(appType: "codex"), .active)
        try withDatabase { db in
            try execute(db, sql: "DROP TABLE proxy_config; CREATE TABLE proxy_config (app_type TEXT)")
        }
        XCTAssertEqual(repository.proxyTakeoverStatus(appType: "codex"), .unavailable)
        XCTAssertTrue(missing.blocksQuickSwitch())
    }

    func testUnavailableProxyEvidenceBlocksAndUIAbsenceStaysConfirmed() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        try withDatabase { db in
            try execute(db, sql: "BEGIN EXCLUSIVE")
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            XCTAssertEqual(repository.proxyTakeoverStatus(appType: "codex"), .unavailable)
            for missingCodexOnly in [false, true] {
                let reader = CCSwitchAggregationRepository(repository: repository, read: { _ in
                    if missingCodexOnly { return Data(#"{"apps":{}}"#.utf8) }
                    throw CocoaError(.fileReadNoSuchFile)
                }, now: { now })
                XCTAssertTrue(reader.blocksQuickSwitch())
                guard case .untrusted = reader.load() else { return XCTFail("unavailable starts untrusted") }
                now.addTimeInterval(CCSwitchAggregationRepository.confirmedAbsenceInterval)
                for _ in 0..<3 {
                    guard case .inactive = reader.load() else { return XCTFail("confirmed absence must stay inactive") }
                    XCTAssertTrue(reader.blocksQuickSwitch(), "UI timeout must not release protection")
                }
            }
        }
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
                XCTAssertEqual(message, tr(.keyQuickSwitchStateUntrusted))
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
    func testMergedThirdPartyDefaultOutsideStackOwnsWebsiteAndBalanceMetadata() throws {
        try withDatabase { db in
            try execute(db, sql: "UPDATE providers SET website_url='https://default.example' WHERE id='codex-custom'")
            try execute(db, sql: """
                INSERT INTO providers SELECT 'peer', name, settings_config, meta, category, 'https://member.example',
                    app_type, 0, 3, 3 FROM providers WHERE id='codex-custom'
                """)
        }
        let reader = aggregationReader(try aggregationState(route: "codex-custom", members: ["peer"]))
        guard case .active(let entries) = reader.load() else { return XCTFail("expected aggregation") }
        XCTAssertEqual(entries.map(\.providerID), ["peer", "codex-custom"], "default was appended outside stack")
        for defaultOffset in [-10.0, 10.0] {
            let base = Date(timeIntervalSince1970: 100)
            let context = BalanceProgressContext(baselineCents: 500, lastCents: 373, peakCents: 500, baselineObservedAt: base)
            let recharge = BalanceRecharge(amountCents: 200, observedAt: base)
            let displays = entries.map { entry in
                let date = base.addingTimeInterval(entry.role == .default ? defaultOffset : 0)
                return AggregatedProviderDisplay(entry: entry,
                    identity: .init(providerID: entry.providerID, accountScope: entry.providerID, configurationRevision: "fixture"),
                    snapshot: .balance(entry.source.name, 3.73, "USD", entry.source.websiteURL, date,
                        progressPercentage: entry.role == .default ? 74.6 : 90,
                        recharge: entry.role == .default ? recharge : nil,
                        progressContext: entry.role == .default ? context : nil),
                    account: nil, status: .fresh, reason: nil, fetchedAt: date)
            }
            let cards = AggregationWalletPresentation.cards(displays)
            XCTAssertEqual(cards.count, 1)
            let card = try XCTUnwrap(cards.first)
            XCTAssertEqual(card.entry.role, .default)
            XCTAssertEqual(card.entry.providerID, "codex-custom")
            XCTAssertEqual(card.entry.source.websiteURL?.absoluteString, "https://default.example")
            XCTAssertEqual(card.snapshot.websiteURL, card.entry.source.websiteURL)
            XCTAssertEqual(card.snapshot.amount, 3.73)
            XCTAssertEqual(card.snapshot.balanceRecharge, recharge)
            XCTAssertEqual(card.snapshot.balanceProgressContext, context)
            XCTAssertEqual(card.snapshot.balanceProgressPercentage, 74.6)
            XCTAssertEqual(card.fetchedAt, base.addingTimeInterval(defaultOffset))
            XCTAssertEqual(card.groupedProviderIDs, ["peer", "codex-custom"])
            var unavailableDefault = displays
            unavailableDefault[1].snapshot = .providerError(card.entry.source.name, reason: "offline", cachedBalance: nil)
            unavailableDefault[1].status = .error
            let fallback = try XCTUnwrap(AggregationWalletPresentation.cards(unavailableDefault,
                partitions: ["peer": "shared", "codex-custom": "shared"]).first)
            XCTAssertEqual(fallback.entry.providerID, "peer")
            XCTAssertEqual(fallback.snapshot.websiteURL?.absoluteString, "https://member.example")
            XCTAssertEqual(fallback.snapshot.websiteURL, fallback.entry.source.websiteURL)
            XCTAssertEqual(fallback.fetchedAt, base)
            XCTAssertEqual(fallback.status, .stale)
        }
    }

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
            XCTAssertEqual(entries.map(\.providerID), ["codex-custom", "peer", "codex-official"])
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
        XCTAssertEqual(AggregationWalletPresentation.cards(before).first(where: { !$0.entry.source.isOfficial })?.groupedNotes, ["Grok", "GPT"])
        try withDatabase { db in try execute(db, sql: "UPDATE providers SET sort_index=0 WHERE id='peer'") }
        let after = try displays()
        XCTAssertNotEqual(before, after, "display order must invalidate semantic publication even with unchanged IDs/data")
        XCTAssertEqual(AggregationWalletPresentation.cards(after).first(where: { !$0.entry.source.isOfficial })?.groupedNotes, ["GPT", "Grok"])
        XCTAssertEqual(try currentValue(for: "codex-custom"), 1)
    }
}

extension CCSwitchRepositoryTests {
    func testMetadataReaderDropsOldCompletionAndDoesNotBlockCaller() throws {
        let olderStarted = DispatchSemaphore(value: 0)
        let releaseOlder = DispatchSemaphore(value: 0)
        let callbacks = DispatchQueue(label: "test.metadata.callbacks")
        let newer = expectation(description: "newest metadata published")
        let old = expectation(description: "old metadata must not replace newest")
        old.isInverted = true
        let reader = ProviderMetadataReader(queue: DispatchQueue(label: "test.metadata.reads", attributes: .concurrent),
            callbackQueue: callbacks) { app in
            XCTAssertFalse(Thread.isMainThread)
            if app == "old" { olderStarted.signal(); releaseOlder.wait() }
            return .init(choices: [.init(id: app, name: app, isCurrent: true)], current: nil, sources: [])
        }
        reader.reload(appType: "old") { _ in old.fulfill() }
        XCTAssertEqual(olderStarted.wait(timeout: .now() + 2), .success)
        reader.reload(appType: "new") { value in XCTAssertEqual(value.choices.first?.id, "new"); newer.fulfill() }
        wait(for: [newer], timeout: 2)
        releaseOlder.signal()
        wait(for: [old], timeout: 0.2)
    }

    func testMissingStateAfterKnownAggregationStillBlocksSwitch() throws {
        let state = try aggregationState()
        var missing = false
        var replacement: Data?
        let reader = CCSwitchAggregationRepository(repository: repository, isRunning: { true }, read: { _ in
            if missing { throw CocoaError(.fileReadNoSuchFile) }
            return replacement ?? state
        })
        guard case .active = reader.load() else { return XCTFail("fixture active") }
        missing = true
        XCTAssertTrue(reader.blocksQuickSwitch())
        guard case .untrusted = reader.load() else { return XCTFail("temporary missing state") }
        missing = false
        replacement = Data(#"{"apps":{}}"#.utf8)
        XCTAssertTrue(reader.blocksQuickSwitch(), "partial valid JSON must not remove known aggregation protection")
        guard case .untrusted = reader.load() else { return XCTFail("partial JSON is not confirmed exit") }
    }

    func testColdStartMissingStateUsesDatabaseProxyEvidence() throws {
        try withDatabase { db in
            try execute(db, sql: "UPDATE proxy_config SET live_takeover_active = 1 WHERE app_type = 'codex'")
        }
        defer {
            try? withDatabase { db in
                try execute(db, sql: "UPDATE proxy_config SET live_takeover_active = 0 WHERE app_type = 'codex'")
            }
        }
        let reader = CCSwitchAggregationRepository(repository: repository, read: { _ in
            throw CocoaError(.fileReadNoSuchFile)
        })
        XCTAssertTrue(reader.blocksQuickSwitch())
        guard case .untrusted = reader.load() else { return XCTFail("active database takeover must remain untrusted") }
    }
}

extension CCSwitchRepositoryTests {
    func testMetadataBusyReadPreservesLastPublishedChoices() throws {
        let failed = expectation(description: "SQLite busy reached background read")
        let ready = expectation(description: "initial choices cached")
        let unexpected = expectation(description: "failed read must not publish empty choices")
        unexpected.isInverted = true
        let reader = ProviderMetadataReader(queue: DispatchQueue(label: "test.metadata.sqlite"), callbackQueue: .main) { [repository] app in
            XCTAssertFalse(Thread.isMainThread)
            do { return .init(choices: try repository!.loadChoicesChecked(appType: app), current: nil, sources: nil) }
            catch { failed.fulfill(); throw error }
        }
        var cached: [ProviderChoice] = []
        reader.reload(appType: "codex") { cached = $0.choices; ready.fulfill() }
        wait(for: [ready], timeout: 2)
        let trusted = cached
        try withDatabase { db in
            try execute(db, sql: "BEGIN EXCLUSIVE")
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            reader.reload(appType: "codex") { _ in unexpected.fulfill() }
            wait(for: [failed, unexpected], timeout: 0.5)
            XCTAssertEqual(cached, trusted)
        }
    }
}
