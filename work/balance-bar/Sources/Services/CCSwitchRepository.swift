import Foundation
import SQLite3

struct CCSwitchProvider {
    let id: String
    let name: String
    let isOfficial: Bool
    let query: BalanceQuery?
    let queryFailure: BalanceQueryFailure?
    let openCodexCandidate: OpenCodexEndpointCandidate?
}

final class CCSwitchRepository {
    static let defaultDatabaseURL = URL(fileURLWithPath: NSString(
        string: "~/.cc-switch/cc-switch.db"
    ).expandingTildeInPath)

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let databaseURL: URL
    private let appSettingsURL: URL
    private let homeDirectoryURL: URL

    init(
        databaseURL: URL = CCSwitchRepository.defaultDatabaseURL,
        appSettingsURL: URL? = nil,
        homeDirectoryURL: URL? = nil
    ) {
        self.databaseURL = databaseURL
        self.appSettingsURL = appSettingsURL ?? databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json")
        let isDefaultDatabase = databaseURL.standardizedFileURL
            == CCSwitchRepository.defaultDatabaseURL.standardizedFileURL
        self.homeDirectoryURL = homeDirectoryURL ?? (
            isDefaultDatabase
                ? FileManager.default.homeDirectoryForCurrentUser
                : databaseURL.deletingLastPathComponent()
        )
    }

    convenience init(
        databasePath: String,
        appSettingsURL: URL? = nil,
        homeDirectoryURL: URL? = nil
    ) {
        self.init(
            databaseURL: URL(fileURLWithPath: databasePath),
            appSettingsURL: appSettingsURL,
            homeDirectoryURL: homeDirectoryURL
        )
    }

    func loadCurrent(appType: String) -> CCSwitchProvider? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else { return nil }
        defer { sqlite3_close(database) }

        let sql = "SELECT id, name, settings_config, meta, category, website_url FROM providers WHERE app_type = ? AND is_current = 1 LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(appType, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = text(from: statement, column: 0),
              let name = text(from: statement, column: 1),
              let configText = text(from: statement, column: 2),
              let metaText = text(from: statement, column: 3) else { return nil }
        let category = text(from: statement, column: 4)
        let websiteText = text(from: statement, column: 5)
        guard category != "official" else {
            return CCSwitchProvider(
                id: id,
                name: name,
                isOfficial: true,
                query: nil,
                queryFailure: nil,
                openCodexCandidate: nil
            )
        }

        var queryFailure: BalanceQueryFailure?
        let query = BalanceQuery.make(
            settingsText: configText,
            metaText: metaText,
            websiteText: websiteText,
            appType: appType,
            onFailure: { queryFailure = $0 }
        )
        return CCSwitchProvider(
            id: id,
            name: name,
            isOfficial: false,
            query: query,
            queryFailure: queryFailure,
            openCodexCandidate: OpenCodexEndpointCandidate.parse(settingsConfig: configText)
        )
    }

    func loadChoices(appType: String) -> [ProviderChoice] {
        let fileManager = FileManager.default
        let databaseExists = fileManager.fileExists(atPath: databaseURL.path)
        let databaseReadable = fileManager.isReadableFile(atPath: databaseURL.path)
        let attributes = try? fileManager.attributesOfItem(atPath: databaseURL.path)
        let databaseSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        SwitchLog.write(
            "provider choices read started; app_type=\(appType); database_path=\(databaseURL.path); exists=\(databaseExists); readable=\(databaseReadable); size=\(databaseSize)",
            level: .debug,
            category: "provider.read",
            throttleKey: "provider-read-start-\(appType)",
            minimumInterval: 1
        )

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let database else {
            let error = database.map { String(cString: sqlite3_errmsg($0)) } ?? "no sqlite handle"
            if let database { sqlite3_close(database) }
            SwitchLog.write(
                "provider choices read failed; app_type=\(appType); stage=open; sqlite_code=\(openCode); error=\(error)",
                level: .error,
                category: "provider.read"
            )
            return []
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT id, name, is_current FROM providers WHERE app_type = ? ORDER BY COALESCE(sort_index, 999999), created_at, id"
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            SwitchLog.write(
                "provider choices read failed; app_type=\(appType); stage=prepare; sqlite_code=\(prepareCode); error=\(String(cString: sqlite3_errmsg(database)))",
                level: .error,
                category: "provider.read"
            )
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(appType, to: statement, at: 1)

        var result: [ProviderChoice] = []
        var rowCount = 0
        var skippedRowCount = 0
        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_DONE { break }
            guard stepCode == SQLITE_ROW else {
                SwitchLog.write(
                    "provider choices read failed; app_type=\(appType); stage=step; sqlite_code=\(stepCode); error=\(String(cString: sqlite3_errmsg(database)))",
                    level: .error,
                    category: "provider.read"
                )
                break
            }
            rowCount += 1
            guard let id = text(from: statement, column: 0),
                  let name = text(from: statement, column: 1) else {
                skippedRowCount += 1
                SwitchLog.write(
                    "provider row skipped; app_type=\(appType); row=\(rowCount); reason=missing id or name",
                    level: .warning,
                    category: "provider.read"
                )
                continue
            }
            result.append(ProviderChoice(
                id: id,
                name: name,
                isCurrent: sqlite3_column_int(statement, 2) != 0
            ))
        }

        let choiceSummary = result.map {
            "id=\($0.id),name=\($0.name),current=\($0.isCurrent)"
        }.joined(separator: "|")
        SwitchLog.write(
            "provider choices read completed; app_type=\(appType); row_count=\(rowCount); result_count=\(result.count); skipped_rows=\(skippedRowCount); choices=\(choiceSummary.isEmpty ? "<empty>" : choiceSummary)",
            category: "provider.read",
            throttleKey: "provider-read-complete-\(appType)",
            minimumInterval: 1
        )
        return result
    }

    func loadSummarySources(appType: String) -> [ProviderSummarySource] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else { return [] }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)

        let sql = "SELECT id, settings_config, meta, category, website_url FROM providers WHERE app_type = ? ORDER BY COALESCE(sort_index, 999999), created_at, id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(appType, to: statement, at: 1)

        var result: [ProviderSummarySource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(from: statement, column: 0) else { continue }
            let settingsText = text(from: statement, column: 1) ?? "{}"
            let metaText = text(from: statement, column: 2) ?? "{}"
            let category = text(from: statement, column: 3)
            let websiteText = text(from: statement, column: 4)

            if category == "official" {
                let stored = settingsText.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let auth = stored?["auth"] as? [String: Any]
                let tokens = auth?["tokens"] as? [String: Any]
                let accessToken = tokens?["access_token"] as? String
                result.append(ProviderSummarySource(
                    id: id,
                    isOfficial: true,
                    query: nil,
                    officialAccessToken: accessToken,
                    openCodexCandidate: nil
                ))
            } else {
                let query = BalanceQuery.make(
                    settingsText: settingsText,
                    metaText: metaText,
                    websiteText: websiteText,
                    appType: appType
                )
                result.append(ProviderSummarySource(
                    id: id,
                    isOfficial: false,
                    query: query,
                    officialAccessToken: nil,
                    openCodexCandidate: appType == "codex"
                        ? OpenCodexEndpointCandidate.parse(settingsConfig: settingsText)
                        : nil
                ))
            }
        }
        return result
    }

    func switchCurrent(to providerID: String, appType: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw switchError(tr("无法打开 CC Switch 数据库", "Unable to open the CC Switch database"))
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)

        guard let target = loadSwitchTarget(providerID, appType: appType, database: database) else {
            throw switchError(tr("供应商不存在", "Provider does not exist"))
        }

        var appSettings = (try? Data(contentsOf: appSettingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let preserveOfficialAuth = appSettings["preserveCodexOfficialAuthOnSwitch"] as? Bool ?? false
        let unifyHistory = appSettings["unifyCodexSessionHistory"] as? Bool ?? true

        if !proxyTakeoverIsActive(appType: appType, database: database) {
            if appType == "claude" {
                guard
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(target.settingsConfig.utf8)
                    ) as? [String: Any]
                else {
                    throw switchError(tr(
                        "供应商的 Claude 配置不完整",
                        "The Provider's Claude configuration is incomplete"
                    ))
                }
                let settingsURL = homeDirectoryURL
                    .appendingPathComponent(".claude", isDirectory: true)
                    .appendingPathComponent("settings.json")
                try FileManager.default.createDirectory(
                    at: settingsURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let settingsData = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try settingsData.write(to: settingsURL, options: .atomic)
            } else {
                guard let stored = try? JSONSerialization.jsonObject(with: Data(target.settingsConfig.utf8)) as? [String: Any],
                      let auth = stored["auth"],
                      var config = stored["config"] as? String else {
                    throw switchError(tr("供应商的 Codex 配置不完整", "The Provider's Codex configuration is incomplete"))
                }

                let codexDirectory = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
                let authURL = codexDirectory.appendingPathComponent("auth.json")
                let configURL = codexDirectory.appendingPathComponent("config.toml")
                try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

                // CC Switch syncs MCP entries separately after a provider switch.
                // Preserve the currently enabled live MCP sections here as well.
                let liveConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
                config = replacingMCPSections(in: config, with: mcpSections(from: liveConfig))

                if target.category == "official", unifyHistory {
                    config = injectingUnifiedOfficialRoute(into: config)
                }

                if target.category != "official", preserveOfficialAuth {
                    if let authObject = auth as? [String: Any],
                       let token = authObject["OPENAI_API_KEY"] as? String, !token.isEmpty {
                        config = injectingBearerToken(token, into: config)
                    }
                } else {
                    let authData = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
                    try authData.write(to: authURL, options: .atomic)
                }
                try Data(config.utf8).write(to: configURL, options: .atomic)
            }
        }

        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw switchError(tr("CC Switch 数据库正忙", "The CC Switch database is busy"))
        }
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) } }
        try execute(
            database,
            sql: "UPDATE providers SET is_current = 0 WHERE app_type = ?",
            bindings: [appType]
        )
        try execute(
            database,
            sql: "UPDATE providers SET is_current = 1 WHERE id = ? AND app_type = ?",
            bindings: [providerID, appType]
        )
        guard sqlite3_changes(database) == 1 else {
            throw switchError(tr("未能选中供应商", "Unable to select the Provider"))
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw switchError(tr("无法保存供应商切换", "Unable to save the Provider switch"))
        }
        committed = true

        appSettings[appType == "claude" ? "currentProviderClaude" : "currentProviderCodex"] = providerID
        let settingsData = try JSONSerialization.data(withJSONObject: appSettings, options: [.prettyPrinted, .sortedKeys])
        try settingsData.write(to: appSettingsURL, options: .atomic)
    }

    private struct SwitchTarget {
        let settingsConfig: String
        let category: String?
    }

    private func loadSwitchTarget(
        _ id: String,
        appType: String,
        database: OpaquePointer
    ) -> SwitchTarget? {
        var statement: OpaquePointer?
        let sql = "SELECT settings_config, category FROM providers WHERE id = ? AND app_type = ? LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1)
        bind(appType, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let settingsText = text(from: statement, column: 0) else { return nil }
        return SwitchTarget(settingsConfig: settingsText, category: text(from: statement, column: 1))
    }

    private func proxyTakeoverIsActive(appType: String, database: OpaquePointer) -> Bool {
        let sql = "SELECT EXISTS(SELECT 1 FROM proxy_config WHERE app_type = ? AND (live_takeover_active = 1 OR enabled = 1)) OR EXISTS(SELECT 1 FROM proxy_live_backup WHERE app_type = ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(appType, to: statement, at: 1)
        bind(appType, to: statement, at: 2)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) != 0
    }

    private func execute(_ database: OpaquePointer, sql: String, bindings: [String] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw switchError(tr("数据库写入准备失败", "Failed to prepare the database write"))
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            bind(binding, to: statement, at: Int32(index + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw switchError(tr("数据库写入失败", "Database write failed"))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func text(from statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func mcpSections(from config: String) -> String {
        var collecting = false
        var lines: [String] = []
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                collecting = trimmed == "[mcp_servers]" || trimmed.hasPrefix("[mcp_servers.")
            }
            if collecting { lines.append(line) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacingMCPSections(in config: String, with replacement: String) -> String {
        var skipping = false
        var lines: [String] = []
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                skipping = trimmed == "[mcp_servers]" || trimmed.hasPrefix("[mcp_servers.")
            }
            if !skipping { lines.append(line) }
        }
        var result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !replacement.isEmpty { result += "\n\n" + replacement }
        return result + "\n"
    }

    private func injectingUnifiedOfficialRoute(into config: String) -> String {
        if config.range(of: #"(?m)^\s*model_provider\s*="#, options: .regularExpression) != nil { return config }
        if config.contains("[model_providers.custom]") { return config }
        return "model_provider = \"custom\"\n" + config.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" +
            "[model_providers.custom]\nname = \"OpenAI\"\nrequires_openai_auth = true\nsupports_websockets = true\nwire_api = \"responses\"\n"
    }

    private func injectingBearerToken(_ token: String, into config: String) -> String {
        let escaped = token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let line = "experimental_bearer_token = \"\(escaped)\""
        if config.range(of: #"(?m)^\s*experimental_bearer_token\s*="#, options: .regularExpression) != nil {
            return config.replacingOccurrences(of: #"(?m)^\s*experimental_bearer_token\s*=.*$"#, with: line, options: .regularExpression)
        }
        guard let header = config.range(of: #"(?m)^\[model_providers\.[^\]]+\]\s*$"#, options: .regularExpression) else {
            return config + "\n" + line + "\n"
        }
        return config[..<header.upperBound] + "\n" + line + config[header.upperBound...]
    }

    private func switchError(_ message: String) -> NSError {
        NSError(domain: "BalanceBar.ProviderSwitch", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
