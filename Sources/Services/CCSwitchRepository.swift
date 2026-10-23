import Foundation
import SQLite3
import CryptoKit

struct CCSwitchProvider {
    let id: String
    let name: String
    let isOfficial: Bool
    let query: BalanceQuery?
    let queryFailure: BalanceQueryFailure?
    var configurationRevision: String = ""
}

enum CCSwitchProxyTakeoverStatus: Equatable {
    case active
    case inactive
    case unavailable
}

/// Proxy values read from Claude Code's user settings. The raw URL is kept
/// only long enough to build an injected URLSession configuration; callers do
/// not log or expose it.
struct CCSwitchProxyConfiguration: Equatable {
    let httpsProxy: URL?
    let allProxy: URL?

    init(httpsProxy: URL? = nil, allProxy: URL? = nil) {
        self.httpsProxy = httpsProxy
        self.allProxy = allProxy
    }

    var isEmpty: Bool { httpsProxy == nil && allProxy == nil }
}

enum CCSwitchQuickSwitchSafety: Equatable {
    case allowedDirect, allowedLegacyDirect
    case blockedAggregation, blockedRouting, blockedUntrusted

    var isBlocked: Bool { self != .allowedDirect && self != .allowedLegacyDirect }
    var hint: String {
        switch self {
        case .blockedAggregation: return tr(.keyAggregationManageInCCSwitch)
        case .blockedRouting: return tr(.keyQuickSwitchRoutingProtected)
        default: return tr(.keyQuickSwitchStateUntrusted)
        }
    }
}

enum CCSwitchConnectionMode: Equatable, Sendable {
    case direct, aggregation, proxy, unknown
}

/// One app's connection mode plus the provider names the General page shows
/// beside it: the current provider for direct/proxy, the stack members
/// (default route first) for aggregation, and no names for `.unknown`.
struct CCSwitchConnectionSummary: Equatable, Sendable {
    let mode: CCSwitchConnectionMode
    let providerNames: [String]

    static let unknown = CCSwitchConnectionSummary(mode: .unknown, providerNames: [])
}

/// All three apps' display data from one read pass.
struct CCSwitchConnectionSummaries: Equatable, Sendable {
    let codex: CCSwitchConnectionSummary
    let claude: CCSwitchConnectionSummary
    let grok: CCSwitchConnectionSummary

    static let unknown = CCSwitchConnectionSummaries(
        codex: .unknown, claude: .unknown, grok: .unknown
    )
}

enum CCSwitchReadError: Error {
    case sqlite(Int32)
    var sqliteCode: Int32 { switch self { case .sqlite(let code): return code } }
}

final class CCSwitchRepository {
    static let defaultDatabaseURL = URL(fileURLWithPath: NSString(
        string: "~/.cc-switch/cc-switch.db"
    ).expandingTildeInPath)

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let loadChoicesObserverLock = NSLock()
    private var loadChoicesObserverStorage: (() -> Void)?
    private var loadSummarySourcesObserverStorage: (([String]?) -> Void)?

    /// Tests may observe provider-list reads. Production leaves this nil.
    var loadChoicesObserver: (() -> Void)? {
        get {
            loadChoicesObserverLock.lock()
            defer { loadChoicesObserverLock.unlock() }
            return loadChoicesObserverStorage
        }
        set {
            loadChoicesObserverLock.lock()
            loadChoicesObserverStorage = newValue
            loadChoicesObserverLock.unlock()
        }
    }

    /// Receives the provider ID filter (nil for a full-list read).
    var loadSummarySourcesObserver: (([String]?) -> Void)? {
        get {
            loadChoicesObserverLock.lock()
            defer { loadChoicesObserverLock.unlock() }
            return loadSummarySourcesObserverStorage
        }
        set {
            loadChoicesObserverLock.lock()
            loadSummarySourcesObserverStorage = newValue
            loadChoicesObserverLock.unlock()
        }
    }

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
        try? loadCurrentChecked(appType: appType)
    }

    func configurationRevision(appType: String, providerID: String) -> String? {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        return configurationRevision(appType: appType, providerID: providerID, database: database)
    }

    private func configurationRevision(appType: String, providerID: String, database: OpaquePointer) -> String? {
        let sql = "SELECT id, name, settings_config, meta, category, website_url FROM providers WHERE app_type = ? AND id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(appType, to: statement, at: 1)
        bind(providerID, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = text(from: statement, column: 0),
              let name = text(from: statement, column: 1),
              let settings = text(from: statement, column: 2),
              let meta = text(from: statement, column: 3) else { return nil }
        let category = text(from: statement, column: 4)
        let website = text(from: statement, column: 5)
        return SHA256.hash(data: Data([id, name, settings, meta, category ?? "", website ?? ""].joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func proxyTakeoverStatus(appType: String) -> CCSwitchProxyTakeoverStatus {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return .unavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)

        return proxyTakeoverStatus(appType: appType, database: database)
    }

    private func proxyTakeoverStatus(appType: String, database: OpaquePointer, includeSyncedEnabled: Bool = true) -> CCSwitchProxyTakeoverStatus {
        let tableExists: (String) -> Bool? = { table in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return nil }
            self.bind(table, to: statement, at: 1)
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { return nil }
            return step == SQLITE_ROW
        }

        guard let hasProxyConfig = tableExists("proxy_config") else { return .unavailable }
        guard let hasBackup = tableExists("proxy_live_backup") else { return .unavailable }
        guard hasProxyConfig || hasBackup else { return .inactive }

        var proxyColumns: Set<String> = []
        if hasProxyConfig {
            var columns: OpaquePointer?
            defer { sqlite3_finalize(columns) }
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(proxy_config)", -1, &columns, nil) == SQLITE_OK,
                  let columns else { return .unavailable }
            var step = sqlite3_step(columns)
            while step == SQLITE_ROW {
                if let name = text(from: columns, column: 1) { proxyColumns.insert(name) }
                step = sqlite3_step(columns)
            }
            guard step == SQLITE_DONE else { return .unavailable }
        }

        var active = false
        if hasProxyConfig, includeSyncedEnabled, proxyColumns.contains("enabled") {
            let predicate = proxyColumns.contains("live_takeover_active") ? "(enabled = 1 OR live_takeover_active = 1)" : "enabled = 1"
            let sql = "SELECT EXISTS(SELECT 1 FROM proxy_config WHERE app_type = ? AND \(predicate))"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return .unavailable }
            bind(appType, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return .unavailable }
            active = sqlite3_column_int(statement, 0) != 0
        } else if hasProxyConfig, proxyColumns.contains("live_takeover_active") {
            let sql = "SELECT EXISTS(SELECT 1 FROM proxy_config WHERE app_type = ? AND live_takeover_active = 1)"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return .unavailable }
            bind(appType, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return .unavailable }
            active = sqlite3_column_int(statement, 0) != 0
        } else if hasProxyConfig && !proxyColumns.contains("enabled") {
            return .unavailable
        }

        if hasBackup {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT EXISTS(SELECT 1 FROM proxy_live_backup WHERE app_type = ?)"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return .unavailable }
            bind(appType, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return .unavailable }
            active = active || sqlite3_column_int(statement, 0) != 0
        }
        return active ? .active : .inactive
    }

    var deviceStateURL: URL { homeDirectoryURL.appendingPathComponent(".cc-switch/live-state.json") }

    /// One app's view of CC Switch's live-state.json, shared by quick-switch
    /// safety and connection-summary reads so the two cannot diverge. A
    /// missing file or missing app entry keeps `mode == nil` (legacy direct);
    /// a present-but-untrusted payload reports `.untrusted`. Stack member IDs
    /// and the default route are display-only extras the safety checks ignore.
    private enum DeviceAppState: Equatable {
        case trusted(
            mode: String?, hasEntry: Bool, stackEnabled: Bool, attached: Bool,
            stackMembers: [String], route: String?
        )
        case untrusted
    }

    private static func parseDeviceAppState(_ data: Data?, appType: String) -> DeviceAppState {
        let absent = DeviceAppState.trusted(
            mode: nil, hasEntry: false, stackEnabled: false, attached: false,
            stackMembers: [], route: nil
        )
        guard let data else { return absent }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] == nil || ((object["version"] as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.intValue == 1 && $0.doubleValue == 1 } == true),
              let apps = object["apps"] as? [String: Any] else { return .untrusted }
        guard let raw = apps[appType] else { return absent }
        guard let entry = raw as? [String: Any],
              entry["pending"] == nil || entry["pending"] is NSNull else { return .untrusted }
        let stack = entry["stack"] as? [String: Any]
        return .trusted(
            mode: entry["mode"] as? String,
            hasEntry: true,
            stackEnabled: stack?["enabled"] as? Bool == true,
            attached: entry["attached"] as? Bool == true,
            stackMembers: (stack?["members"] as? [String] ?? []).filter { !$0.isEmpty },
            route: (entry["proxy_route"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Read-only connection mode for the General page. Unreadable or untrusted
    /// state — including a missing CC Switch install — reports `.unknown`
    /// instead of guessing.
    func connectionMode(appType: String, stateURL: URL? = nil, readState: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> CCSwitchConnectionMode {
        let data = try? readState(stateURL ?? deviceStateURL)
        return Self.connectionMode(appType: appType, stateData: data)
    }

    /// Display data for the General page's CC Switch row: one state read for
    /// all three apps' modes, then one database read for the current provider
    /// names and aggregation stack members. A database that cannot be opened
    /// leaves the names empty without failing the modes.
    func connectionSummaries(stateURL: URL? = nil, readState: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> CCSwitchConnectionSummaries {
        let data = try? readState(stateURL ?? deviceStateURL)
        let codexState = Self.parseDeviceAppState(data, appType: "codex")
        var codex = CCSwitchConnectionSummary(mode: Self.connectionMode(appType: "codex", stateData: data), providerNames: [])
        var claude = CCSwitchConnectionSummary(mode: Self.connectionMode(appType: "claude", stateData: data), providerNames: [])
        var grok = CCSwitchConnectionSummary(mode: Self.connectionMode(appType: "grokbuild", stateData: data), providerNames: [])

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        // Issue #577 acceptance: an unreadable database must degrade the whole
        // display to 未知 instead of showing modes without complete evidence.
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return .unknown
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)

        // Current provider names for all three apps in one query.
        var currentNames: [String: String] = [:]
        var currentStatement: OpaquePointer?
        defer { sqlite3_finalize(currentStatement) }
        let currentSQL = "SELECT app_type, name FROM providers WHERE is_current = 1 AND app_type IN ('codex', 'claude', 'grokbuild')"
        guard sqlite3_prepare_v2(database, currentSQL, -1, &currentStatement, nil) == SQLITE_OK, let currentStatement else {
            return .unknown
        }
        // A read can still fail mid-iteration (BUSY after the 100 ms wait,
        // IOERR); only SQLITE_DONE counts as a complete result.
        var currentStep = sqlite3_step(currentStatement)
        while currentStep == SQLITE_ROW {
            if let appType = text(from: currentStatement, column: 0),
               let name = text(from: currentStatement, column: 1) {
                currentNames[appType] = name
            }
            currentStep = sqlite3_step(currentStatement)
        }
        guard currentStep == SQLITE_DONE else { return .unknown }
        claude = Self.displaySummary(mode: claude.mode, names: currentNames["claude"].map { [$0] } ?? [])
        grok = Self.displaySummary(mode: grok.mode, names: currentNames["grokbuild"].map { [$0] } ?? [])
        if codex.mode == .aggregation,
           case let .trusted(_, _, _, _, stackMembers, route) = codexState {
            // Default route first, then the remaining members in stack order.
            var ids: [String] = []
            for id in ([route].compactMap { $0 } + stackMembers) where !ids.contains(id) {
                ids.append(id)
            }
            guard let members = providerNames(database: database, appType: "codex", ids: ids) else {
                return .unknown
            }
            codex = Self.displaySummary(mode: codex.mode, names: members)
        } else {
            codex = Self.displaySummary(mode: codex.mode, names: currentNames["codex"].map { [$0] } ?? [])
        }
        return CCSwitchConnectionSummaries(codex: codex, claude: claude, grok: grok)
    }

    /// An unknown mode never carries provider names: without a trustworthy
    /// state the display must not guess a provider either.
    private static func displaySummary(mode: CCSwitchConnectionMode, names: [String]) -> CCSwitchConnectionSummary {
        CCSwitchConnectionSummary(mode: mode, providerNames: mode == .unknown ? [] : names)
    }

    /// nil when the member query cannot run; callers degrade to `.unknown`.
    private func providerNames(database: OpaquePointer, appType: String, ids: [String]) -> [String]? {
        guard !ids.isEmpty else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT id, name FROM providers WHERE app_type = ? AND id IN (" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        bind(appType, to: statement, at: 1)
        for (index, id) in ids.enumerated() { bind(id, to: statement, at: Int32(index + 2)) }
        var byID: [String: String] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let id = text(from: statement, column: 0),
               let name = text(from: statement, column: 1) {
                byID[id] = name
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return nil }
        return ids.compactMap { byID[$0] }
    }

    private static func connectionMode(appType: String, stateData: Data?) -> CCSwitchConnectionMode {
        guard appType == "codex" || appType == "claude" || appType == "grokbuild" else { return .unknown }
        guard case let .trusted(mode, hasEntry, stackEnabled, attached, _, _) = parseDeviceAppState(stateData, appType: appType),
              hasEntry, let mode else { return .unknown }
        switch mode {
        case "direct":
            // `attached` marks proxy-managed residue; a "direct" claim with it
            // is not trustworthy, exactly like quick-switch safety.
            return attached ? .unknown : .direct
        case "proxy":
            // CC Switch's stack aggregation is Codex-only; other apps' proxy
            // takeovers stay `.proxy`, mirroring quick-switch safety.
            return appType == "codex" && stackEnabled ? .aggregation : .proxy
        default:
            return .unknown
        }
    }

    /// Reads only the proxy settings used for Claude's official HTTPS quota
    /// request. Invalid or non-string values fail closed to direct transport.
    func claudeProxyConfiguration(
        readSettings: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> CCSwitchProxyConfiguration {
        let settingsURL = homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        guard let data = try? readSettings(settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any] else {
            return CCSwitchProxyConfiguration()
        }
        return CCSwitchProxyConfiguration(
            httpsProxy: Self.proxyURL(from: env["HTTPS_PROXY"]),
            allProxy: Self.proxyURL(from: env["ALL_PROXY"])
        )
    }

    private static func proxyURL(from value: Any?) -> URL? {
        guard let raw = value as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "socks", "socks5", "socks5h"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    private func proxyHistoryKey(appType: String) -> String {
        let scope = homeDirectoryURL.standardizedFileURL.path + "|" + databaseURL.standardizedFileURL.path + "|" + appType
        return "quickSwitch.proxyObserved." + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func quickSwitchSafety(appType: String = "codex", stateURL: URL? = nil, readState: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> CCSwitchQuickSwitchSafety {
        guard appType == "codex" || appType == "claude" else { return .blockedUntrusted }
        let proxyHistoryKey = proxyHistoryKey(appType: appType)
        // Remember a local proxy observation even when the database is temporarily unavailable.
        if let data = try? readState(stateURL ?? deviceStateURL),
           case let .trusted(mode, _, _, _, _, _) = Self.parseDeviceAppState(data, appType: appType),
           mode == "proxy", !UserDefaults.standard.bool(forKey: proxyHistoryKey) {
            UserDefaults.standard.set(true, forKey: proxyHistoryKey)
        }
        var database: OpaquePointer?
        let code = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard code == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return .blockedUntrusted
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        return quickSwitchSafety(database: database, appType: appType, stateURL: stateURL ?? deviceStateURL, readState: readState)
    }

    private func quickSwitchSafety(database: OpaquePointer, appType: String, stateURL: URL, liveProviderID: String? = nil, readState: (URL) throws -> Data) -> CCSwitchQuickSwitchSafety {
        let proxyHistoryKey = proxyHistoryKey(appType: appType)
        do {
            func stateData() throws -> Data? {
                do { return try readState(stateURL) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
            }
            let before = try stateData()
            guard case let .trusted(mode, hasEntry, stackEnabled, attached, _, _) = Self.parseDeviceAppState(before, appType: appType) else {
                return .blockedUntrusted
            }
            if mode == "proxy" {
                if !UserDefaults.standard.bool(forKey: proxyHistoryKey) { UserDefaults.standard.set(true, forKey: proxyHistoryKey) }
                return appType == "codex" && stackEnabled
                    ? .blockedAggregation : .blockedRouting
            }
            if hasEntry {
                guard mode == "direct", !attached else { return .blockedUntrusted }
            }
            let evidence = proxyTakeoverStatus(appType: appType, database: database, includeSyncedEnabled: mode != "direct")
            guard evidence == .inactive else { return .blockedUntrusted }
            if mode == nil && UserDefaults.standard.bool(forKey: proxyHistoryKey) { return .blockedUntrusted }
            let matches = appType == "codex"
                ? directCodexConfigurationMatches(database: database, providerID: liveProviderID)
                : directClaudeConfigurationMatches(database: database, providerID: liveProviderID)
            guard matches, before == (try stateData()) else { return .blockedUntrusted }
            if mode == "direct" {
                if UserDefaults.standard.bool(forKey: proxyHistoryKey) { UserDefaults.standard.removeObject(forKey: proxyHistoryKey) }
                return .allowedDirect
            }
            return .allowedLegacyDirect
        } catch { return .blockedUntrusted }
    }

    /// Compare only the effective route and credential strategy, never unrelated MCP/project content.
    private func directCodexConfigurationMatches(database: OpaquePointer, providerID: String? = nil) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT settings_config, category FROM providers WHERE app_type = 'codex' AND " + (providerID == nil ? "is_current = 1" : "id = ?"), -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        if let providerID { bind(providerID, to: statement, at: 1) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let stored = text(from: statement, column: 0),
              let row = try? JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any] else { return false }
        let official = text(from: statement, column: 1) == "official"
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        let directory = homeDirectoryURL.appendingPathComponent(".codex")
        let config: String
        do { config = try String(contentsOf: directory.appendingPathComponent("config.toml"), encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Codex defaults to the official route without a user TOML file.
            guard official else { return false }
            config = ""
        } catch { return false }
        guard !config.contains("PROXY_MANAGED"), !config.contains("cc-switch-official") else { return false }
        let authURL = directory.appendingPathComponent("auth.json")
        let auth: [String: Any]
        do {
            let data = try Data(contentsOf: authURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !String(decoding: data, as: UTF8.self).contains("PROXY_MANAGED") else { return false }
            auth = object
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { auth = [:] }
        catch { return false }
        guard let actual = Self.codexRoute(config) else { return false }
        let expected: [String: String]
        if let text = row["config"] as? String {
            guard let route = Self.codexRoute(text) else { return false }
            expected = route
        } else if let url = row["base_url"] as? String {
            expected = ["base_url": url]
        } else if official { expected = [:] }
        else { return false }
        // Empty route means Codex's built-in official route, including the existing unified-history mirror.
        guard actual.filter({ $0.key != "experimental_bearer_token" }) == expected.filter({ $0.key != "experimental_bearer_token" }) else { return false }
        if official { return actual["experimental_bearer_token"] == nil }
        let expectedAuth = row["auth"] as? [String: Any] ?? [:]
        let expectedKey = expected["experimental_bearer_token"] ?? expectedAuth["OPENAI_API_KEY"] as? String ?? row["api_key"] as? String
        let actualKey = actual["experimental_bearer_token"] ?? auth["OPENAI_API_KEY"] as? String
        return expectedKey == actualKey && (expectedKey != nil || expected["env_key"] != nil)
    }

    private func directClaudeConfigurationMatches(database: OpaquePointer, providerID: String?) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT settings_config FROM providers WHERE app_type = 'claude' AND " + (providerID == nil ? "is_current = 1" : "id = ?")
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        if let providerID { bind(providerID, to: statement, at: 1) }
        guard sqlite3_step(statement) == SQLITE_ROW, let stored = text(from: statement, column: 0),
              let expected = try? JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any],
              sqlite3_step(statement) == SQLITE_DONE else { return false }
        let actual: [String: Any]
        do {
            let data = try Data(contentsOf: homeDirectoryURL.appendingPathComponent(".claude/settings.json"))
            guard !String(decoding: data, as: UTF8.self).contains("PROXY_MANAGED"),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            actual = object
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { actual = [:] }
        catch { return false }
        func route(_ object: [String: Any]) -> [String: String]? {
            guard object["apiKeyHelper"] == nil else { return nil }
            guard object["env"] == nil || object["env"] is [String: String] else { return nil }
            let env = object["env"] as? [String: String] ?? [:]
            guard !env.values.contains(where: { $0.contains("PROXY_MANAGED") }) else { return nil }
            return Self.managedClaudeEnvironment(env)
        }
        guard let expectedRoute = route(expected), let actualRoute = route(actual) else { return false }
        return expectedRoute == actualRoute
    }

    /// The provider card owns the routing and credential selectors. Proxy,
    /// telemetry, TLS and other user-owned environment keys do not establish
    /// whether CC Switch's direct route is still intact.
    private static func managedClaudeEnvironment(_ env: [String: String]) -> [String: String] {
        var managed = env.filter { key, _ in
            switch key {
            case "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                 "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
                 "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                 "AWS_REGION", "AWS_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                 "GOOGLE_CLOUD_PROJECT", "GOOGLE_APPLICATION_CREDENTIALS", "CLOUD_ML_REGION":
                return true
            default:
                let uppercased = key.uppercased()
                if key.hasPrefix("ANTHROPIC_") {
                    return uppercased.contains("TOKEN") || uppercased.contains("API_KEY")
                        || uppercased.contains("MODEL") || uppercased.contains("BEDROCK")
                        || uppercased.contains("VERTEX") || uppercased.contains("FOUNDRY")
                }
                return key.hasPrefix("CLAUDE_CODE_USE_")
                    || (key.hasPrefix("CLAUDE_CODE_") && uppercased.contains("MODEL"))
            }
        }
        if let baseURL = managed["ANTHROPIC_BASE_URL"], isOfficialClaudeBaseURL(baseURL) {
            managed.removeValue(forKey: "ANTHROPIC_BASE_URL")
        }
        return managed
    }

    private static func isOfficialClaudeBaseURL(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.anthropic.com",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    /// Strict single-line routing subset. Unsupported/ambiguous routing syntax fails closed.
    private static func codexRoute(_ config: String) -> [String: String]? {
        var section = ""
        var values: [String: [String: String]] = [:]
        let relevant: Set<String> = ["model_provider", "base_url", "openai_base_url", "env_key", "experimental_bearer_token", "wire_api"]
        for raw in config.components(separatedBy: .newlines) {
            // Multiline strings require a full TOML parser; never infer a route from their contents.
            guard !raw.contains("\"\"\""), !raw.contains("'" + "''") else { return nil }
            var quoted: Character?
            var escaped = false
            var line = ""
            for char in raw {
                if char == "#" && quoted == nil { break }
                line.append(char)
                if escaped { escaped = false; continue }
                if char == "\\" && quoted == "\"" { escaped = true; continue }
                if let quote = quoted { if char == quote { quoted = nil } }
                else if char == "\"" || char == "'" { quoted = char }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { return nil }
                if line.hasPrefix("[[") {
                    guard !line.contains("model_providers") else { return nil }
                    section = "ignored-array"
                    continue
                }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard section.isEmpty || section.hasPrefix("model_providers.") else { continue }
            guard let equal = line.firstIndex(of: "=") else { return nil }
            let rawKey = line[..<equal].trimmingCharacters(in: .whitespaces)
            let key: String
            if rawKey.hasPrefix("\"") {
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(rawKey.utf8), options: .fragmentsAllowed) as? String else { return nil }
                key = parsed
            } else if rawKey.hasPrefix("'") && rawKey.hasSuffix("'") { key = String(rawKey.dropFirst().dropLast()) }
            else { key = rawKey }
            if section.isEmpty && (key == "profile" || key == "model_providers" || key.hasPrefix("model_providers.")) { return nil }
            guard relevant.contains(key) else { continue }
            let literal = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            let value: String
            if literal.hasPrefix("\""), let parsed = try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as? String { value = parsed }
            else if literal.hasPrefix("'"), literal.hasSuffix("'"), literal.count >= 2 { value = String(literal.dropFirst().dropLast()) }
            else { return nil }
            guard values[section]?[key] == nil else { return nil }
            values[section, default: [:]][key] = value
        }
        let top = values[""] ?? [:]
        let selector = top["model_provider"] ?? "openai"
        guard selector.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        var route = values["model_providers." + selector] ?? [:]
        if route.isEmpty && selector != "openai" { return nil }
        if let url = top["openai_base_url"] ?? top["base_url"], route["base_url"] == nil { route["base_url"] = url }
        route.removeValue(forKey: "model_provider")
        if route["wire_api"] == "responses" { route.removeValue(forKey: "wire_api") }
        return route
    }

    func loadCurrentChecked(appType: String) throws -> CCSwitchProvider? {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CCSwitchReadError.sqlite(openCode)
        }
        sqlite3_busy_timeout(database, 100)
        defer { sqlite3_close(database) }

        let sql = "SELECT id, name, settings_config, meta, category, website_url FROM providers WHERE app_type = ? AND is_current = 1 LIMIT 1"
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else { throw CCSwitchReadError.sqlite(prepareCode) }
        defer { sqlite3_finalize(statement) }
        bind(appType, to: statement, at: 1)
        let stepCode = sqlite3_step(statement)
        if stepCode == SQLITE_DONE { return nil }
        guard stepCode == SQLITE_ROW else { throw CCSwitchReadError.sqlite(stepCode) }
        guard let id = text(from: statement, column: 0),
              let name = text(from: statement, column: 1),
              let configText = text(from: statement, column: 2),
              let metaText = text(from: statement, column: 3) else { return nil }
        let category = text(from: statement, column: 4)
        let websiteText = text(from: statement, column: 5)
        let revision = SHA256.hash(data: Data([id, name, configText, metaText, category ?? "", websiteText ?? ""].joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let configurationFailure = Self.officialConfigurationFailure(
            category: category, settingsText: configText, metaText: metaText
        ) {
            return CCSwitchProvider(
                id: id,
                name: name,
                isOfficial: false,
                query: nil,
                queryFailure: configurationFailure,
                configurationRevision: revision
            )
        }
        guard !Self.usesOfficialQuota(category: category, settingsText: configText, metaText: metaText, appType: appType) else {
            return CCSwitchProvider(
                id: id,
                name: name,
                isOfficial: true,
                query: nil,
                queryFailure: nil,
                configurationRevision: revision
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
            configurationRevision: revision
        )
    }

    // A CCS "official" card may contain a pay-as-you-go API key. Do not
    // substitute the locally signed-in subscription's quota for that identity.
    private static func usesOfficialQuota(
        category: String?, settingsText: String, metaText: String, appType: String
    ) -> Bool {
        guard category == "official" else { return false }
        if appType == "codex" {
            let meta = metaText.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let binding = meta?["authBinding"] as? [String: Any]
            let accountID = (binding?["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if binding?["source"] as? String == "managed_account",
               binding?["authProvider"] as? String == "codex_oauth",
               accountID?.isEmpty == false {
                return true
            }
        }
        // Use the same credential locations as balance queries.
        return !BalanceQuery.containsAPICredential(settingsText: settingsText, metaText: metaText)
    }

    private static func officialConfigurationFailure(
        category: String?, settingsText: String, metaText: String
    ) -> BalanceQueryFailure? {
        guard category == "official" else { return nil }
        guard let settingsData = settingsText.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: settingsData)) is [String: Any]
        else { return .settingsJSONInvalid }
        guard let metaData = metaText.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: metaData)) is [String: Any]
        else { return .metaJSONInvalid }
        return nil
    }

    func loadChoices(appType: String) -> [ProviderChoice] {
        (try? loadChoicesChecked(appType: appType)) ?? []
    }

    func loadChoicesChecked(appType: String) throws -> [ProviderChoice] {
        let observer = loadChoicesObserver
        observer?()
        let fileManager = FileManager.default
        let databaseExists = fileManager.fileExists(atPath: databaseURL.path)
        let databaseReadable = fileManager.isReadableFile(atPath: databaseURL.path)
        let attributes = try? fileManager.attributesOfItem(atPath: databaseURL.path)
        let databaseSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        SwitchLog.write(
            "provider choices read started; app_type=\(appType); exists=\(databaseExists); readable=\(databaseReadable); size=\(databaseSize)",
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
                "provider choices read failed; app_type=\(appType); stage=open; sqlite_code=\(openCode); error_category=sqlite_error",
                level: .error,
                category: "provider.read"
            )
            throw CCSwitchReadError.sqlite(openCode)
        }
        sqlite3_busy_timeout(database, 100)
        defer { sqlite3_close(database) }

        let sql = "SELECT id, name, is_current FROM providers WHERE app_type = ? ORDER BY COALESCE(sort_index, 999999), created_at, id"
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            SwitchLog.write(
                "provider choices read failed; app_type=\(appType); stage=prepare; sqlite_code=\(prepareCode); error_category=sqlite_error",
                level: .error,
                category: "provider.read"
            )
            throw CCSwitchReadError.sqlite(prepareCode)
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
                    "provider choices read failed; app_type=\(appType); stage=step; sqlite_code=\(stepCode); error_category=sqlite_error",
                    level: .error,
                    category: "provider.read"
                )
                throw CCSwitchReadError.sqlite(stepCode)
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

        SwitchLog.write(
            "provider choices read completed; app_type=\(appType); row_count=\(rowCount); result_count=\(result.count); skipped_rows=\(skippedRowCount); choices_omitted=true",
            category: "provider.read",
            throttleKey: "provider-read-complete-\(appType)",
            minimumInterval: 1
        )
        return result
    }

    func loadSummarySources(appType: String) -> [ProviderSummarySource] {
        (try? loadSummarySourcesChecked(appType: appType)) ?? []
    }

    /// A single read transaction; callers must distinguish SQL failure from an empty list.
    func loadSummarySourcesChecked(appType: String, providerIDs: [String]? = nil) throws -> [ProviderSummarySource] {
        loadSummarySourcesObserver?(providerIDs)
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CCSwitchAggregationReadError.databaseUnavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw CCSwitchAggregationReadError.databaseUnavailable
        }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

        if providerIDs?.isEmpty == true { return [] }
        let filter = providerIDs.map { " AND id IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
        var columns: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(providers)", -1, &columns, nil) == SQLITE_OK,
              let columns else { throw CCSwitchAggregationReadError.databaseUnavailable }
        var hasNotes = false
        var columnStep = sqlite3_step(columns)
        while columnStep == SQLITE_ROW {
            if text(from: columns, column: 1) == "notes" { hasNotes = true }
            columnStep = sqlite3_step(columns)
        }
        sqlite3_finalize(columns)
        guard columnStep == SQLITE_DONE else { throw CCSwitchAggregationReadError.databaseUnavailable }
        let notesColumn = hasNotes ? "notes" : "NULL"
        let sql = "SELECT id, name, settings_config, meta, category, website_url, created_at, \(notesColumn) FROM providers WHERE app_type = ?" + filter + " ORDER BY COALESCE(sort_index, 999999), created_at, id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CCSwitchAggregationReadError.databaseUnavailable }
        defer { sqlite3_finalize(statement) }
        bind(appType, to: statement, at: 1)

        for (index, id) in (providerIDs ?? []).enumerated() { bind(id, to: statement, at: Int32(index + 2)) }
        var result: [ProviderSummarySource] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard let id = text(from: statement, column: 0) else { continue }
            let name = text(from: statement, column: 1) ?? ""
            let settingsText = text(from: statement, column: 2) ?? "{}"
            let metaText = text(from: statement, column: 3) ?? "{}"
            let category = text(from: statement, column: 4)
            let websiteText = text(from: statement, column: 5)
            let websiteURL = safeWebsiteURL(from: websiteText)
            let rawNotes = text(from: statement, column: 7)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = rawNotes?.isEmpty == false ? rawNotes : nil

            let revisionData = Data([id, name, settingsText, metaText, category ?? "", websiteText ?? "", String(sqlite3_column_int64(statement, 6))].joined(separator: "\u{0}").utf8)
            let revision = SHA256.hash(data: revisionData).map { String(format: "%02x", $0) }.joined()
            if Self.officialConfigurationFailure(category: category, settingsText: settingsText, metaText: metaText) != nil {
                result.append(ProviderSummarySource(
                    id: id,
                    name: name,
                    isOfficial: false,
                    query: nil,
                    officialAccessToken: nil,
                    websiteURL: websiteURL,
                    configurationRevision: revision,
                    notes: notes
                ))
            } else if Self.usesOfficialQuota(category: category, settingsText: settingsText, metaText: metaText, appType: appType) {
                let stored = settingsText.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let auth = stored?["auth"] as? [String: Any]
                let tokens = auth?["tokens"] as? [String: Any]
                let accessToken = tokens?["access_token"] as? String
                let profile = auth.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { CredentialReader.codexAccountProfile(from: $0) }
                result.append(ProviderSummarySource(
                    id: id,
                    name: name,
                    isOfficial: true,
                    query: nil,
                    officialAccessToken: accessToken,
                    websiteURL: websiteURL,
                    configurationRevision: revision,
                    officialAccount: profile,
                    notes: notes
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
                    name: name,
                    isOfficial: false,
                    query: query,
                    officialAccessToken: nil,
                    websiteURL: websiteURL,
                    configurationRevision: revision,
                    notes: notes
                ))
            }
        }
        guard step == SQLITE_DONE else { throw CCSwitchAggregationReadError.databaseUnavailable }
        return result
    }

    private func safeWebsiteURL(from text: String?) -> URL? {
        guard let text,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    /// Tests can change evidence at exact transaction boundaries; production leaves this nil.
    var switchWriteObserver: ((String) -> Void)?

    func switchCurrent(to providerID: String, appType: String,
                       expectedCurrentRevision: String? = nil, expectedTargetRevision: String? = nil) throws {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw switchError(tr(.keyCCSwitchRepositoryUnableToOpenTheCcSwitchDatabase))
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)

        guard let target = loadSwitchTarget(providerID, appType: appType, database: database) else {
            throw switchError(tr(.keyCCSwitchRepositoryProviderDoesNotExist))
        }

        if appType != "codex", appType != "claude" {
            throw switchError(tr(.keyCCSwitchRepositoryProviderDoesNotExist))
        }
        let readFile: (URL) throws -> Data? = { url in
            do { return try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
        let codexDirectory = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        let inputURLs = appType == "codex"
            ? [appSettingsURL, codexDirectory.appendingPathComponent("config.toml"), codexDirectory.appendingPathComponent("auth.json"), deviceStateURL]
            : [appSettingsURL, homeDirectoryURL.appendingPathComponent(".claude/settings.json"), deviceStateURL]
        let inputs = try inputURLs.map { (url: $0, data: try readFile($0)) }
        let initialState = inputs.first { $0.url == deviceStateURL }?.data
        var appSettings: [String: Any] = [:]
        if let data = inputs.first?.data {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw switchError(tr(.keyQuickSwitchStateUntrusted))
            }
            appSettings = parsed
        }
        let preserveOfficialAuth = appSettings["preserveCodexOfficialAuthOnSwitch"] as? Bool ?? false
        let unifyHistory = appSettings["unifyCodexSessionHistory"] as? Bool ?? true

        let currentID: String? = {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT id FROM providers WHERE app_type = ? AND is_current = 1", -1, &statement, nil) == SQLITE_OK,
                  let statement else { return nil }
            bind(appType, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return text(from: statement, column: 0)
        }()
        let currentRevision = currentID.flatMap { configurationRevision(appType: appType, providerID: $0, database: database) }
        let targetRevision = configurationRevision(appType: appType, providerID: providerID, database: database)
        guard let currentRevision, let targetRevision,
              expectedCurrentRevision == nil || expectedCurrentRevision == currentRevision,
              expectedTargetRevision == nil || expectedTargetRevision == targetRevision else {
            throw switchError(tr(.keyQuickSwitchStateUntrusted))
        }
        do {
            guard !quickSwitchSafety(database: database, appType: appType, stateURL: deviceStateURL, readState: { try Data(contentsOf: $0) }).isBlocked else {
                throw switchError(tr(.keyQuickSwitchStateUntrusted))
            }
        }
        var writes: [(url: URL, data: Data)] = []
        do {
            if appType == "claude" {
                guard
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(target.settingsConfig.utf8)
                    ) as? [String: Any]
                else {
                    throw switchError(tr(.keyCCSwitchRepositoryTheProviderSClaudeConfigurationIsIncomplete))
                }
                let settingsURL = homeDirectoryURL
                    .appendingPathComponent(".claude", isDirectory: true)
                    .appendingPathComponent("settings.json")
                // Quick Switch owns only the Provider environment. Preserve all
                // independent user settings, including unknown future fields.
                let liveData = inputs.first(where: { $0.url == settingsURL })?.data
                var settings = try liveData.map { data -> [String: Any] in
                    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw switchError(tr(.keyQuickSwitchStateUntrusted))
                    }
                    return value
                } ?? [:]
                guard object["env"] == nil || object["env"] is [String: String] else {
                    throw switchError(tr(.keyCCSwitchRepositoryTheProviderSClaudeConfigurationIsIncomplete))
                }
                settings["env"] = object["env"] // Absent target env removes stale Provider credentials.
                let settingsData = try JSONSerialization.data(
                    withJSONObject: settings,
                    options: [.prettyPrinted, .sortedKeys]
                )
                writes.append((settingsURL, settingsData))
            } else {
                guard let stored = try? JSONSerialization.jsonObject(with: Data(target.settingsConfig.utf8)) as? [String: Any],
                      let auth = stored["auth"],
                      var config = stored["config"] as? String else {
                    throw switchError(tr(.keyCCSwitchRepositoryTheProviderSCodexConfigurationIsIncomplete))
                }

                let codexDirectory = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
                let authURL = codexDirectory.appendingPathComponent("auth.json")
                let configURL = codexDirectory.appendingPathComponent("config.toml")

                // CC Switch syncs MCP entries separately after a provider switch.
                // Preserve the currently enabled live MCP sections here as well.
                let liveConfig = inputs.first(where: { $0.url == configURL })?.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
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
                    writes.append((authURL, authData))
                }
                writes.append((configURL, Data(config.utf8)))
            }
        }

        if appType == "claude" {
            appSettings["currentProviderClaude"] = providerID
        } else if appType == "codex" {
            appSettings["currentProviderCodex"] = providerID
        }
        let settingsData = try JSONSerialization.data(withJSONObject: appSettings, options: [.prettyPrinted, .sortedKeys])
        writes.append((appSettingsURL, settingsData))

        switchWriteObserver?("afterPrepare")
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw switchError(tr(.keyCCSwitchRepositoryTheCcSwitchDatabaseIsBusy))
        }
        var committed = false
        var published: [(url: URL, before: Data?, after: Data)] = []
        let originals = writes.map { file in inputs.first(where: { $0.url == file.url })!.data }
        defer {
            if !committed {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                for file in published.reversed() {
                    // Never overwrite a subsequent writer's changes during recovery.
                    if (try? readFile(file.url)) == file.after {
                        if let before = file.before { try? before.write(to: file.url, options: .atomic) }
                        else { try? FileManager.default.removeItem(at: file.url) }
                    }
                }
            }
        }
        func validateInputs() throws {
            for input in inputs {
                let expected = published.first(where: { $0.url == input.url })?.after ?? input.data
                guard (try readFile(input.url)) == expected else { throw switchError(tr(.keyQuickSwitchStateUntrusted)) }
            }
        }
        func validate(liveProviderID: String? = nil) throws {
            guard let currentID, isCurrent(providerID: currentID, appType: appType, database: database),
                  loadSwitchTarget(providerID, appType: appType, database: database) == target,
                  configurationRevision(appType: appType, providerID: currentID, database: database) == currentRevision,
                  configurationRevision(appType: appType, providerID: providerID, database: database) == targetRevision else {
                throw switchError(tr(.keyQuickSwitchStateUntrusted))
            }
            do {
                guard (try readFile(deviceStateURL)) == initialState,
                      !quickSwitchSafety(database: database, appType: appType, stateURL: deviceStateURL, liveProviderID: liveProviderID,
                          readState: { try Data(contentsOf: $0) }).isBlocked else {
                    throw switchError(tr(.keyQuickSwitchStateUntrusted))
                }
            }
        }
        switchWriteObserver?("beforePublish")
        try validateInputs()
        try validate()
        for (index, file) in writes.enumerated() {
            switchWriteObserver?("beforeFile")
            try validateInputs()
            do {
                guard (try readFile(deviceStateURL)) == initialState else {
                    throw switchError(tr(.keyQuickSwitchStateUntrusted))
                }
            }
            try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: file.url, options: .atomic)
            published.append((file.url, originals[index], file.data))
        }
        switchWriteObserver?("beforePointer")
        try validateInputs()
        try validate(liveProviderID: providerID)
        try validateInputs()
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
            throw switchError(tr(.keyCCSwitchRepositoryUnableToSelectTheProvider))
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw switchError(tr(.keyCCSwitchRepositoryUnableToSaveTheProviderSwitch))
        }
        committed = true

    }

    private func isCurrent(providerID: String, appType: String, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM providers WHERE id = ? AND app_type = ? AND is_current = 1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        bind(providerID, to: statement, at: 1)
        bind(appType, to: statement, at: 2)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private struct SwitchTarget: Equatable {
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

    private func execute(_ database: OpaquePointer, sql: String, bindings: [String] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw switchError(tr(.keyCCSwitchRepositoryFailedToPrepareTheDatabaseWrite))
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            bind(binding, to: statement, at: Int32(index + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw switchError(tr(.keyCCSwitchRepositoryDatabaseWriteFailed))
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

/// Latest-request-wins metadata delivery. Every SQLite read runs on `queue`;
/// failures retain the caller's last published value instead of clearing it.
final class ProviderMetadataReader {
    struct Value {
        let choices: [ProviderChoice]
        let current: CCSwitchProvider?
        let sources: [ProviderSummarySource]?
    }
    private let read: (String, Bool) throws -> Value
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var generation: UInt64 = 0

    init(repository: CCSwitchRepository,
         queue: DispatchQueue = DispatchQueue(label: "local.balancebar.provider-metadata", qos: .utility, attributes: .concurrent),
         callbackQueue: DispatchQueue = .main) {
        self.read = { appType, includeSources in
            Value(choices: try repository.loadChoicesChecked(appType: appType),
                  current: try repository.loadCurrentChecked(appType: appType),
                  sources: includeSources ? try repository.loadSummarySourcesChecked(appType: appType) : nil)
        }
        self.queue = queue
        self.callbackQueue = callbackQueue
    }

    init(queue: DispatchQueue, callbackQueue: DispatchQueue, read: @escaping (String) throws -> Value) {
        self.queue = queue; self.callbackQueue = callbackQueue
        self.read = { appType, _ in try read(appType) }
    }

    func reload(appType: String, includeSources: Bool = true, publish: @escaping (Value) -> Void) {
        lock.lock(); generation &+= 1; let token = generation; lock.unlock()
        queue.async { [weak self] in
            guard let self, let value = try? self.read(appType, includeSources) else { return }
            self.callbackQueue.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let current = self.generation == token; self.lock.unlock()
                guard current else { return }
                publish(value)
            }
        }
    }
}
