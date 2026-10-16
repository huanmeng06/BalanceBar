import AppKit
import Foundation
import Darwin

enum DashboardLogging {
    static func number(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    static func rect(_ rect: NSRect) -> String {
        "x=\(number(rect.origin.x)),y=\(number(rect.origin.y)),w=\(number(rect.size.width)),h=\(number(rect.size.height))"
    }

    static func state(_ state: NSControl.StateValue) -> String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .mixed: return "mixed"
        default: return "raw=\(state.rawValue)"
        }
    }
}

enum SwitchLog {
    enum Level: String { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    enum ReadResult: Equatable {
        case empty
        case data(String, truncated: Bool, warnings: [String])
        case failure(String)
    }

    private static let queue = DispatchQueue(label: "local.balancebar.debug-log")
    private static let maximumSize = 5 * 1_024 * 1_024
    private static let maximumArchives = 10
    private static let maximumStorageSize = 60 * 1_024 * 1_024
    private static let viewerMaximumBytes = 160 * 1_024
    private static var lastWriteDates: [String: Date] = [:]
    private static var sessionID: String?
    private static var testingDirectoryURL: URL?
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var environmentName: String {
        let bundle = Bundle.main.bundleIdentifier ?? ""
        return bundle == "com.huanmeng06.BalanceBar.dev" || bundle.hasPrefix("com.huanmeng06.BalanceBar.dev.") ? "Development" : "Production"
    }

    static var directoryURL: URL {
        if let testingDirectoryURL { return testingDirectoryURL }
        if let override = ProcessInfo.processInfo.environment["BALANCEBAR_LOG_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSString(string: "~/Library/Logs/BalanceBar/\(environmentName)").expandingTildeInPath, isDirectory: true)
    }

    static func setTestingDirectory(_ url: URL?) {
        queue.sync { testingDirectoryURL = url; sessionID = nil }
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("debug.log") }
    private static var sequenceURL: URL { directoryURL.appendingPathComponent(".sequence") }
    private static var lockURL: URL { directoryURL.appendingPathComponent(".lock") }
    private static var legacyFileURL: URL { URL(fileURLWithPath: NSString(string: "~/Library/Logs/BalanceBar/debug.log").expandingTildeInPath) }
    private static var legacyPreviousURL: URL { legacyFileURL.deletingLastPathComponent().appendingPathComponent("debug.previous.log") }

    static var archiveURLs: [URL] {
        scanFiles().files.filter { $0.lastPathComponent.hasPrefix("debug-") && $0.pathExtension == "log" }
    }

    static func write(_ message: String, level: Level = .info, category: String = "general", throttleKey: String? = nil, minimumInterval: TimeInterval = 0) {
        queue.async {
            let now = Date()
            if minimumInterval > 0 {
                let key = throttleKey ?? "\(level.rawValue)|\(category)|\(message)"
                if let previous = lastWriteDates[key], now.timeIntervalSince(previous) < minimumInterval { return }
                lastWriteDates[key] = now
                if lastWriteDates.count > 256 { lastWriteDates = lastWriteDates.filter { now.timeIntervalSince($0.value) < 3_600 } }
            }
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try withFileLock {
                    do {
                        try ensureSessionStarted(at: now)
                        try appendRecord(try makeRecord(message, level: level, category: category, date: now))
                    } catch {
                        NSLog("BalanceBar diagnostic log deferred; error_code=%ld", error._code)
                    }
                    pruneArchives()
                }
            } catch { NSLog("BalanceBar debug log error; error_code=%ld", error._code) }
        }
    }

    static func startSession() {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try withFileLock { try ensureSessionStarted(at: Date()) }
            } catch { NSLog("BalanceBar session start deferred; error_code=%ld", error._code) }
        }
    }

    static func recentText() -> String? {
        switch readSnapshot() { case .data(let text, _, _): return text; default: return nil }
    }

    static func readSnapshot() -> ReadResult {
        queue.sync {
            do { return try withFileLock { readSnapshotLocked(previewLimit: viewerMaximumBytes) } }
            catch { return .failure("无法锁定诊断日志（锁错误）") }
        }
    }

    static func exportAll(to destination: URL) throws {
        let protected = [fileURL, sequenceURL, lockURL, legacyFileURL, legacyPreviousURL] + archiveURLs
            let destinationURL = destination.standardizedFileURL
            guard !protected.contains(where: { $0.standardizedFileURL == destinationURL }) else {
                throw NSError(domain: "BalanceBar.Diagnostics", code: 4, userInfo: [NSLocalizedDescriptionKey: "The export destination is part of the diagnostic store."])
            }
            let snapshot = try withFileLock { readFilesLocked(previewLimit: nil) }
            guard !snapshot.text.isEmpty else { throw NSError(domain: "BalanceBar.Diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "No diagnostic logs are available."]) }
            let warningText = redact(snapshot.warnings.joined(separator: " | "))
            let header = "# BalanceBar diagnostic export\n# Environment: \(environmentName)\n# Warnings: \(warningText)\n\n"
            let sanitizedBody = sanitizeExportRecords(snapshot.text)
            guard let data = (header + sanitizedBody).data(using: .utf8) else {
                throw NSError(domain: "BalanceBar.Diagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to encode diagnostic logs."])
            }
        try data.write(to: destination, options: .atomic)
    }

    private static func readSnapshotLocked(previewLimit: Int) -> ReadResult {
        let snapshot = readFilesLocked(previewLimit: previewLimit)
        guard !snapshot.text.isEmpty else {
            return snapshot.warnings.isEmpty ? .empty : .failure(snapshot.warnings.joined(separator: "\n"))
        }
        return .data(snapshot.text, truncated: snapshot.truncated, warnings: snapshot.warnings)
    }

    private struct FileReadSnapshot { var text = ""; var truncated = false; var warnings: [String] = [] }

    private static func readFilesLocked(previewLimit: Int?) -> FileReadSnapshot {
        var urls: [URL] = []
        if testingDirectoryURL == nil {
            if FileManager.default.fileExists(atPath: legacyPreviousURL.path) { urls.append(legacyPreviousURL) }
            if FileManager.default.fileExists(atPath: legacyFileURL.path), legacyFileURL != fileURL { urls.append(legacyFileURL) }
        }
        let scan = scanFiles()
        urls.append(contentsOf: scan.files.filter { $0.lastPathComponent.hasPrefix("debug-") && $0.pathExtension == "log" })
        urls.append(fileURL)
        var output = FileReadSnapshot()
        if let warning = scan.warning { output.warnings.append(warning) }
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let tail = try readTail(of: url, maximumBytes: previewLimit)
                let data = tail.data
                let isValidUTF8 = String(data: data, encoding: .utf8) != nil
                let decoded = String(decoding: data, as: UTF8.self)
                if !isValidUTF8 { output.warnings.append("损坏或非法 UTF-8：\(url.lastPathComponent)") }
                if tail.wasTruncated && previewLimit != nil {
                    output.truncated = true
                    if let newline = decoded.firstIndex(of: "\n") { output.text += String(decoded[decoded.index(after: newline)...]) }
                    else if !decoded.isEmpty { output.text += decoded; output.warnings.append("单条日志记录超过预览限制：\(url.lastPathComponent)") }
                } else { output.text += decoded }
            } catch { output.warnings.append("无法读取诊断文件：\(url.lastPathComponent)") }
        }
        if let previewLimit, output.text.utf8.count > previewLimit {
            let tail = String(decoding: Array(output.text.utf8).suffix(previewLimit), as: UTF8.self)
            output.text = tail.firstIndex(of: "\n").map { String(tail[tail.index(after: $0)...]) } ?? tail
            output.truncated = true
        }
        return output
    }

    private struct TailRead { let data: Data; let wasTruncated: Bool }

    private static func readTail(of url: URL, maximumBytes: Int?) throws -> TailRead {
        guard let maximumBytes else { return TailRead(data: try Data(contentsOf: url), wasTruncated: false) }
        let size = ((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let offset = size > maximumBytes ? size - maximumBytes : 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if offset == 0 { return TailRead(data: try handle.readToEnd() ?? Data(), wasTruncated: false) }
        for backtrack in 0...3 {
            let start = max(0, offset - backtrack)
            try handle.seek(toOffset: UInt64(start))
            let candidate = try handle.readToEnd() ?? Data()
            if String(data: candidate, encoding: .utf8) != nil {
                return TailRead(data: candidate, wasTruncated: true)
            }
        }
        try handle.seek(toOffset: UInt64(offset))
        return TailRead(data: try handle.readToEnd() ?? Data(), wasTruncated: true)
    }

    private static func makeRecord(_ message: String, level: Level, category: String, date: Date) throws -> Data {
        let cleanMessage = redact(message).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        let cleanCategory = redact(category).replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        let prefix = "[\(timestampFormatter.string(from: date))] [\(level.rawValue)] [\(cleanCategory)] [session=\(sessionID ?? "pending")] "
        let suffix = "\n"
        let originalBytes = cleanMessage.utf8.count
        let boundedCategory = String(cleanCategory.prefix(256))
        let boundedPrefix = "[\(timestampFormatter.string(from: date))] [\(level.rawValue)] [\(boundedCategory)] [session=\(sessionID ?? "pending")] "
        let budget = maximumSize - boundedPrefix.utf8.count - suffix.utf8.count
        let body: String
        if originalBytes <= budget { body = cleanMessage }
        else {
            let marker = " … [message-truncated original_bytes=\(originalBytes)]"
            let limit = max(0, budget - marker.utf8.count)
            var count = 0
            var prefix = ""
            for character in cleanMessage {
                let bytes = String(character).utf8.count
                guard count + bytes <= limit else { break }
                prefix.append(character)
                count += bytes
            }
            body = prefix + marker
        }
        return Data((boundedPrefix + body + suffix).utf8)
    }

    private static func ensureSessionStarted(at date: Date) throws {
        guard sessionID == nil else { return }
        let candidate = UUID().uuidString
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let line = "session-start; session_id=\(candidate); started_at=\(timestampFormatter.string(from: date)); version=\(version); environment=\(environmentName); pid=\(ProcessInfo.processInfo.processIdentifier)"
        let old = sessionID
        sessionID = candidate
        do {
            let record = try makeRecord(line, level: .info, category: "lifecycle", date: date)
            try appendRecord(record)
        } catch { sessionID = old; throw error }
    }

    private static func appendRecord(_ data: Data) throws {
        let size = ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size + data.count > maximumSize, FileManager.default.fileExists(atPath: fileURL.path) { try rotate() }
        if !FileManager.default.fileExists(atPath: fileURL.path) { try data.write(to: fileURL, options: .atomic); return }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    private static func rotate() throws {
        let sequence = try nextSequence()
        let stamp = timestampFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archive = directoryURL.appendingPathComponent(String(format: "debug-%020llu-%@.log", sequence, stamp))
        try FileManager.default.moveItem(at: fileURL, to: archive)
    }

    private static func nextSequence() throws -> UInt64 {
        let current = UInt64(String(data: (try? Data(contentsOf: sequenceURL)) ?? Data(), encoding: .utf8) ?? "0") ?? 0
        let next = current + 1
        try Data(String(next).utf8).write(to: sequenceURL, options: .atomic)
        return next
    }

    private static func pruneArchives() {
        let files = archiveURLs
        var sizes: [(URL, Int)] = files.compactMap { url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return (url, size)
        }
        var total = ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            + sizes.reduce(0) { $0 + $1.1 }
        while sizes.count > maximumArchives || total > maximumStorageSize {
            guard let oldest = sizes.first else { break }
            do { try FileManager.default.removeItem(at: oldest.0); sizes.removeFirst(); total -= oldest.1 }
            catch { NSLog("BalanceBar archive prune failed; error_code=%ld", error._code); break }
        }
    }

    private static func scanFiles() -> (files: [URL], warning: String?) {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return (files, nil)
        } catch { return ([], "无法扫描诊断日志目录") }
    }

    private static func withFileLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Unable to open diagnostic log lock."]) }
        var result = flock(descriptor, LOCK_EX)
        while result != 0 && errno == EINTR { result = flock(descriptor, LOCK_EX) }
        guard result == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Unable to acquire diagnostic log lock."])
            close(descriptor)
            throw error
        }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        return try body()
    }

    private static func redact(_ value: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)),
           JSONSerialization.isValidJSONObject(json),
           let sanitized = sanitizedJSON(json),
           let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        let containerFields = try! NSRegularExpression(pattern: #"["']?([A-Za-z_][A-Za-z0-9_-]*)["']?\s*[:=]\s*[\[{]"#)
        let range = NSRange(value.startIndex..., in: value)
        if containerFields.matches(in: value, range: range).contains(where: { match in
            guard let keyRange = Range(match.range(at: 1), in: value) else { return false }
            return isSensitiveField(String(value[keyRange]))
        }) {
            return "[structured-details-omitted]"
        }
        var result = value
        let patterns: [(String, String)] = [
            ("(?i)(authorization|proxy-authorization)\\s*[:=]\\s*(bearer|basic|token|digest|apikey|negotiate)\\s+[^;\\r\\n]+", "$1: $2 [REDACTED]"),
            ("(?i)(cookie|set-cookie)\\s*[:=]\\s*[^\\r\\n]+", "$1: [REDACTED]"),
            ("(?i)([\\\"']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|authorization|password|passwd|pwd|secret|credential|credentials|token|tokens|headers)[\\\"']?\\s*[:=]\\s*)(?:\\[[^\\]]*\\]|\\{[^}]*\\}|[\\\"'][^\\\"']*[\\\"']|[^\\\"',;}\\s]+)", "$1[REDACTED]"),
            ("(?i)(https?://)[^/\\s:@]+:[^@/\\s]+@", "$1[REDACTED]@"),
            ("(?i)(?:api[_-]?key|access[_-]?token|token|password|secret|signature)=([^&#\\s]+)", "[REDACTED]"),
            ("(?i)https?://[^\\s;,]+", "[URL_REDACTED]"),
            ("(?i)\\bsk-(?:ant-)?[A-Za-z0-9_-]{12,}", "[TOKEN_REDACTED]")
        ]
        for (pattern, replacement) in patterns {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            }
        }
        return result
    }

    private static func sanitizeExportRecords(_ text: String) -> String {
        let prefix = try! NSRegularExpression(pattern: #"^\[\d{4}-\d{2}-\d{2}T[^\]]+\] \[(DEBUG|INFO|WARN|ERROR)\] "#)
        var records: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if prefix.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil && !current.isEmpty {
                records.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n" }
            current += line
        }
        if !current.isEmpty { records.append(current) }
        return records.map { redact($0) }.joined(separator: "\n")
    }

    private static func isSensitiveField(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["token", "credential", "secret", "password", "cookie", "authorization", "api_key"].contains { normalized.contains($0) }
            || ["auth", "headers", "passwd", "pwd", "apikey"].contains(normalized)
    }

    private static func sanitizedJSON(_ value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, nested) in dictionary {
                if isSensitiveField(key) {
                    output[key] = "[REDACTED]"
                } else if let sanitized = sanitizedJSON(nested) {
                    output[key] = sanitized
                } else {
                    return nil
                }
            }
            return output
        }
        if let array = value as? [Any] {
            return array.compactMap { sanitizedJSON($0) }
        }
        if let text = value as? String { return redact(text) }
        if value is NSNumber || value is NSNull { return value }
        return nil
    }
}

private let productionBundleIdentifier = "com.huanmeng06.BalanceBar.app"
private let devBundleIdentifier = "com.huanmeng06.BalanceBar.dev"
private let legacyProductionBundleIdentifier = "com.huanmeng06.BalanceBar"
private let legacyBundleIdentifier = "local.balancebar"

private enum DevelopmentReleaseFixture {
    static let environmentKey = "BALANCEBAR_RELEASE_FIXTURE_PATH"

    static func releaseFetcher() -> GitHubReleaseFetching {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let isDevelopmentBundle = bundleIdentifier == devBundleIdentifier
            || bundleIdentifier.hasPrefix(devBundleIdentifier + ".")
        guard isDevelopmentBundle,
              let rawPath = ProcessInfo.processInfo.environment[environmentKey],
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return GitHubReleaseClient()
        }
        return LocalGitHubReleaseFixture(fileURL: URL(fileURLWithPath: rawPath))
    }
}

struct PreferencesMigrationPlan {
    static let quotaProgressKeys = ["quotaProgressEnabledColors", "quotaProgressRedUpperBound", "quotaProgressOrangeUpperBound", "quotaProgressYellowUpperBound"]
    static let keys = [AppPreferences.displayTimeZoneKey, AppPreferences.lastManualDisplayTimeZoneKey, AppPreferences.updateChannelKey, AppPreferences.silentLaunchKey, "appLanguage", "showMenuBarReset", "showMenuBarIcon", "showMenuBarAmount", "animateCodexActivity", "activityPollInterval", "codexUsageRefreshInterval", "postCodexRefreshDuration", "showQuickSwitchMenu", "showOpenChatGPTMenu", "showOpenCCSwitchMenu", "showStatusMenu", "statusLinks", "keepMenuOpenAfterRefresh", AppPreferences.balanceDisplayThresholdKey, AppPreferences.showQuotaProgressBarKey, AppPreferences.menuLunaReserveDisplayModeKey, AppPreferences.menuLunaReserveHideExhaustedQuotaKey, AppPreferences.menuBankedResetDisplayModeKey, AppPreferences.showBankedResetKey, "sortProvidersAlphabetically", "menuBarHorizontalPadding", AppPreferences.menuBarIconDisplayModeKey, AppPreferences.menuBarIconDisplayDelayKey, AppPreferences.menuBarRightClickActionKey, AppPreferences.menuBarReverseMouseButtonsKey, AppPreferences.menuBarAnimationModeKey, AppPreferences.menuBarAnimationFrameRateKey, AppPreferences.menuBarQuotaWindowPreferenceKey, AppPreferences.menuBarQuotaResetDisplayModeKey, AppPreferences.menuBarAutoSwitchLunaReserveKey, AppPreferences.menuBarLunaReserveResetTimeModeKey, AppPreferences.menuBarIconOffsetXKey, AppPreferences.menuBarIconOffsetYKey, AppPreferences.menuBarAmountOffsetXKey, AppPreferences.menuBarAmountOffsetYKey, AppPreferences.menuBarStatusItemWidthAdjustmentKey, AppPreferences.menuBarFontSizePresetKey, AppPreferences.menuBarFontSizeKey, AppPreferences.menuBarPrimaryFontSizeKey, AppPreferences.menuBarSecondaryFontSizeKey, AppPreferences.menuBarIconSizePresetKey, AppPreferences.notificationSettingsKey]

    static func selectedValues(target: [String: Any], production: [String: Any], local: [String: Any]) -> [String: Any] {
        var selected: [String: Any] = [:]
        for key in allKeys where target[key] == nil { selected[key] = production[key] ?? local[key] }
        return selected
    }

    static var allKeys: [String] { quotaProgressKeys + keys }
}

private func migrateLegacyPreferencesIfNeeded() {
    let defaults = UserDefaults.standard
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? productionBundleIdentifier
    AppPreferencesMigration.migrate(
        defaults: defaults,
        bundleIdentifier: bundleIdentifier,
        productionDomain: defaults.persistentDomain(forName: legacyProductionBundleIdentifier) ?? [:],
        localDomain: defaults.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var statusItemController: StatusItemController!
    private let dashboardAccessoryHarness = DashboardAccessoryHarnessController()
    private lazy var dashboardComposition = DashboardCompositionController(
        state: DashboardCompositionState(
            preferences: preferences,
            devBundleIdentifier: devBundleIdentifier,
            providerPollInterval: providerPollInterval,
            currentProviderName: { [weak self] in self?.currentProviderName() ?? tr(.keyAppNotFound) },
            currentProviderIsOfficial: { [weak self] in
                guard let self, self.activeClient == .codex else { return false }
                return self.currentProviderIsOfficialCache
            },
            providerChoices: { [weak self] in self?.providerChoicesCache ?? [] },
            snapshot: { [weak self] in self?.snapshot ?? .placeholder },
            quickSwitchSummaries: { [weak self] in self?.quickSwitchSummariesSnapshot() ?? [:] },
            refreshDate: { [weak self] in self?.refreshDate(for: self?.snapshot ?? .placeholder) },
            menuBarSnapshot: { [weak self] snapshot in self?.menuBarSnapshot(for: snapshot) ?? snapshot },
            iconImage: { [weak self] in self?.statusItemController?.iconImage },
            statusItemVisibility: { [weak self] in
                self?.statusItemController?.statusItemVisibility ?? .unknown
            },
            updateState: { [weak self] in self?.updateService.state ?? .failed(.invalidCurrentVersion) },
            statusLinks: { [weak self] in self?.statusLinks ?? [] },
            defaultStatusLinks: { [weak self] in self?.defaultStatusLinks ?? [] },
            setStatusLinks: { [weak self] links in self?.statusLinks = links },
            notificationConfiguration: DashboardNotificationPageConfiguration(
                coordinator: notificationCoordinator,
                providerChoices: { [weak self] agent in
                    guard let self, let client = agent.assistantClient else { return [] }
                    return self.ccSwitchRepository.loadChoices(appType: client.appType)
                },
                displayTimeZone: { [weak self] in self?.preferences.effectiveDisplayTimeZone ?? .autoupdatingCurrent }
            ),
            snapshotProviderID: { [weak self] in self?.snapshotProviderID },
            aggregationSnapshots: { [weak self] in
                guard let self, self.activeClient == .codex else { return [:] }
                return Dictionary(uniqueKeysWithValues: self.aggregationDisplays.map { ($0.identity.providerID, $0.snapshot) })
            },
            isAggregationMode: { [weak self] in self?.activeClient == .codex && self?.aggregationDisplays.isEmpty == false }
        ),
        actions: DashboardCompositionActions(
            onManualRefresh: { [weak self] in self?.performManualRefresh(source: "dashboard") },
            onSwitchProvider: { [weak self] providerID in self?.switchProvider(providerID) },
            onOpenProvider: { [weak self] providerID in self?.showDashboardProvider(providerID) },
            onSelectProvider: { [weak self] providerID in self?.showDashboardProvider(providerID) },
            isSortAlphabetically: { [weak self] in self?.sortProvidersAlphabetically ?? false },
            setSortAlphabetically: { [weak self] enabled in self?.sortProvidersAlphabetically = enabled },
            onToggle: { [weak self] identifier, enabled in self?.handleDashboardToggle(identifier: identifier, enabled: enabled) },
            onLaunchAtLogin: { [weak self] enabled in self?.handleLaunchAtLoginAction(enabled: enabled) },
            onLaunchWithChatGPT: { [weak self] enabled in self?.handleLaunchWithChatGPTAction(enabled: enabled) },
            onOpenLaunchWithChatGPTSettings: { [weak self] in self?.openLaunchWithChatGPTSettings() },
            onInterval: { [weak self] identifier, value in self?.handleDashboardInterval(identifier: identifier, value: value) },
            onBalanceDisplayThresholdChanged: { [weak self] value in
                self?.handleDashboardBalanceDisplayThresholdChanged(value)
            },
            onQuotaProgressColorConfigurationChanged: { [weak self] configuration in
                self?.handleQuotaProgressColorConfigurationChanged(configuration)
            },
            onOffsetAdjust: { [weak self] identifier, delta in
                self?.handleDashboardOffsetAdjust(identifier: identifier, delta: delta)
            },
            onOffsetValue: { [weak self] identifier, value in
                self?.handleDashboardOffsetValue(identifier: identifier, value: value)
            },
            onOffsetValueEnded: { [weak self] identifier, value in
                self?.handleDashboardOffsetValueEnded(identifier: identifier, value: value)
            },
            onOffsetReset: { [weak self] identifier in
                self?.handleDashboardOffsetReset(identifier: identifier)
            },
            onLanguage: { [weak self] language in self?.applyLanguage(language) },
            onMenuBarFontSizePreset: { [weak self] preset in
                self?.applyMenuBarFontSizePreset(preset)
            },
            onMenuBarIconSizePreset: { [weak self] preset in
                self?.applyMenuBarIconSizePreset(preset)
            },
            onMenuBarIconDisplayModeChanged: { [weak self] mode in
                self?.handleDashboardMenuBarIconDisplayModeChanged(mode)
            },
            onMenuBarIconDisplayDelayChanged: { [weak self] delay in
                self?.handleDashboardMenuBarIconDisplayDelayChanged(delay)
            },
            onMenuBarRightClickActionChanged: { [weak self] action in
                self?.handleDashboardMenuBarRightClickActionChanged(action)
            },
            onMenuBarAnimationModeChanged: { [weak self] mode in
                self?.handleDashboardMenuBarAnimationModeChanged(mode)
            },
            onMenuBarAnimationFrameRateChanged: { [weak self] fps in
                self?.handleDashboardMenuBarAnimationFrameRateChanged(fps)
            },
            onMenuBarQuotaWindowPreferenceChanged: { [weak self] preference in
                self?.handleDashboardQuotaWindowPreferenceChanged(preference)
            },
            onMenuBarQuotaResetDisplayModeChanged: { [weak self] mode in
                self?.handleDashboardQuotaResetDisplayModeChanged(mode)
            },
            onMenuBarLunaReserveResetTimeModeChanged: { [weak self] mode in
                self?.handleDashboardLunaReserveResetTimeModeChanged(mode)
            },
            onLunaReserveDisplayModeChanged: { [weak self] mode in
                self?.handleDashboardLunaReserveDisplayModeChanged(mode)
            },
            onBankedResetDisplayModeChanged: { [weak self] mode in
                self?.handleDashboardBankedResetDisplayModeChanged(mode)
            },
            onUpdateChannelChanged: { [weak self] channel in
                self?.handleUpdateChannelChanged(channel)
            },
            onOpenCCSwitch: { [weak self] in self?.openCCSwitch() },
            onOpenSystemMenuBarSettings: { [weak self] in
                self?.openSystemMenuBarSettings()
            },
            onCheckForUpdates: { [weak self] in self?.updateService.checkForUpdates() },
            onInstallUpdate: { [weak self] in self?.updateService.installAvailableUpdate() },
            onOpenUpdateNotes: { [weak self] in self?.showUpdateNotes() },
            onClamp: { [weak self] in self?.clampDashboardScrollViewBounds() },
            onStatusLinksChanged: { [weak self] in
                guard let self else { return }
                self.statusItemController.updateMenu(input: self.makeStatusItemMenuInput())
            },
            onDidShowPage: { [weak self] in
                guard let self else { return }
                self.updateDashboard(for: self.snapshot, refreshDate: self.refreshDate(for: self.snapshot))
                self.updateService.checkForUpdatesIfNeeded()
            },
            onDidClose: { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                    SwitchLog.write(
                        "dashboard closed; activation_policy=\(String(describing: NSApp.activationPolicy())); status_visible=\(self.statusItemController.isVisible)",
                        category: "ui.status-item"
                    )
                }
            },
            onDidResize: { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.clampDashboardScrollViewBounds() }
            }
        ),
        launchAtLoginController: launchAtLoginController
    )
    private var dashboardIsVisible: Bool { dashboardComposition.isVisible }
    private var dashboardSection: DashboardSection { dashboardComposition.section }
    private var displayTimeZoneObservers: [NSObjectProtocol] = []
    private let languageChangeGate = DashboardLanguageChangeGate()
    private var timer: Timer?
    private var updateCheckTimer: Timer?
    private var activityCoordinator: ActivityCoordinator!
    private var databaseWatcher: CCSwitchDatabaseWatcher!
    private var aggregationRepository: CCSwitchAggregationRepository!
    private var aggregationDisplays: [AggregatedProviderDisplay] = []
    private var snapshotProviderID: String?
    private var aggregationQuickSwitchBlocked = false
    private var currentProviderIsOfficialCache = false
    private var currentAccountProfileCache: CodexAccountProfile?
    private var ccSwitchLifecycleObservers: [NSObjectProtocol] = []
    private var lastSuccessfulRefresh: Date?
    private var dashboardProviderPageRevision: UInt64 = 0
    private var lastProviderID: String?
    /// In-memory provider list and current name. Search reads these values
    /// and does not open the provider database on each query.
    private var providerChoicesCache: [ProviderChoice] = []
    private var providerNotesCache: [String: [String: String]] = [:]
    private lazy var providerMetadataReader = ProviderMetadataReader(repository: ccSwitchRepository)
    private var currentProviderNameCache = ""
    private var clientSnapshots: [
        AssistantClient: (providerID: String, snapshot: Snapshot)
    ] = [:]
    private var snapshot = Snapshot.placeholder
    private var activeProviderWebsite: URL?
    private var activeClient: AssistantClient = .codex
    private var isCodexTaskRunning = false
    private var isClaudeTaskRunning = false
    private var isGrokTaskRunning = false
    private var isClaudeProcessAvailable = false
    private var isGrokProcessAvailable = false
    private var codexActivityRefreshLifecycle = ActivityRefreshLifecycle()
    private var claudeActivityRefreshLifecycle = ActivityRefreshLifecycle()
    private var grokActivityRefreshLifecycle = ActivityRefreshLifecycle()
    private var lifecycle = ApplicationLifecycleState()
    private var lastCodexUsageRefresh: Date?
    private var postCodexRefreshDeadline: Date?
    private let providerPollInterval: TimeInterval = 3
    private let ccSwitchRepository: CCSwitchRepository
    private let officialQuotaClient: OfficialQuotaClient
    private let balanceAPIClient = BalanceAPIClient()
    private let balanceProgressStore = ProviderBalanceProgressStore()
    private lazy var notificationCoordinator = BalanceNotificationCoordinator()
    private var lastNotificationPermissionState: BalanceNotificationPermissionState?
    private var providerRefreshCoordinator: ProviderRefreshCoordinator!
    private var providerSwitchCoordinator: ProviderSwitchCoordinator!
    private let preferences = AppPreferences()
    private let launchAtLoginController: LaunchAtLoginController
    private let launchWithChatGPTController: LaunchWithChatGPTController
    private lazy var currentAgentOpener = CurrentAgentOpener.live(
        openChatGPT: { [weak self] in self?.openChatGPTApplication() }
    )
    private let updateService: UpdateService
    private lazy var updateNotesWindowController = UpdateNotesWindowController(
        onInstall: { [weak self] in self?.updateService.installAvailableUpdate() },
        onIgnore: { [weak self] in self?.updateService.ignoreAvailableUpdate() }
    )
    private var showMenuBarReset: Bool { get { preferences.showMenuBarReset } set { preferences.showMenuBarReset = newValue } }
    private var showMenuBarIcon: Bool { get { preferences.showMenuBarIcon } set { preferences.showMenuBarIcon = newValue } }
    private var showMenuBarAmount: Bool { get { preferences.showMenuBarAmount } set { preferences.showMenuBarAmount = newValue } }
    private var animateCodexActivity: Bool { get { preferences.animateCodexActivity } set { preferences.animateCodexActivity = newValue } }
    private var menuBarAnimationMode: MenuBarAnimationMode {
        get { preferences.menuBarAnimationMode }
        set { preferences.menuBarAnimationMode = newValue }
    }
    private var activityPollInterval: TimeInterval { get { preferences.activityPollInterval } set { preferences.activityPollInterval = newValue } }
    private var codexUsageRefreshInterval: TimeInterval { get { preferences.codexUsageRefreshInterval } set { preferences.codexUsageRefreshInterval = newValue } }
    private var postCodexRefreshDuration: TimeInterval { get { preferences.postCodexRefreshDuration } set { preferences.postCodexRefreshDuration = newValue } }
    private var showQuickSwitchMenu: Bool { get { preferences.showQuickSwitchMenu } set { preferences.showQuickSwitchMenu = newValue } }
    private var showOpenCCSwitchMenu: Bool { get { preferences.showOpenCCSwitchMenu } set { preferences.showOpenCCSwitchMenu = newValue } }
    private var showOpenChatGPTMenu: Bool { get { preferences.showOpenChatGPTMenu } set { preferences.showOpenChatGPTMenu = newValue } }
    private var showStatusMenu: Bool { get { preferences.showStatusMenu } set { preferences.showStatusMenu = newValue } }
    private var statusLinks: [StatusLink] { get { preferences.statusLinks } set { preferences.statusLinks = newValue } }
    private var defaultStatusLinks: [StatusLink] { preferences.defaultStatusLinks }
    private var keepMenuOpenAfterRefresh: Bool { get { preferences.keepMenuOpenAfterRefresh } set { preferences.keepMenuOpenAfterRefresh = newValue } }
    private var sortProvidersAlphabetically: Bool { get { preferences.sortProvidersAlphabetically } set { preferences.sortProvidersAlphabetically = newValue } }
    private var menuBarHorizontalPadding: CGFloat { get { preferences.menuBarHorizontalPadding } set { preferences.menuBarHorizontalPadding = newValue } }
    private var menuBarIconOffsetX: Double { get { preferences.menuBarIconOffsetX } set { preferences.menuBarIconOffsetX = newValue } }
    private var menuBarIconOffsetY: Double { get { preferences.menuBarIconOffsetY } set { preferences.menuBarIconOffsetY = newValue } }
    private var menuBarAmountOffsetX: Double { get { preferences.menuBarAmountOffsetX } set { preferences.menuBarAmountOffsetX = newValue } }
    private var menuBarAmountOffsetY: Double { get { preferences.menuBarAmountOffsetY } set { preferences.menuBarAmountOffsetY = newValue } }
    private var menuBarFontSize: Double { get { preferences.menuBarFontSize } set { preferences.menuBarFontSize = newValue } }
    private var menuBarQuotaWindowPreference: OfficialQuotaWindowPreference {
        get { preferences.menuBarQuotaWindowPreference }
        set { preferences.menuBarQuotaWindowPreference = newValue }
    }
    private var menuBarQuotaResetDisplayMode: OfficialQuotaResetDisplayMode {
        get { preferences.menuBarQuotaResetDisplayMode }
        set { preferences.menuBarQuotaResetDisplayMode = newValue }
    }
    private var menuBarIconDisplayMode: MenuBarIconDisplayMode {
        get { preferences.menuBarIconDisplayMode }
        set { preferences.menuBarIconDisplayMode = newValue }
    }
    private var menuBarIconDisplayDelay: MenuBarIconDisplayDelay {
        get { preferences.menuBarIconDisplayDelay }
        set { preferences.menuBarIconDisplayDelay = newValue }
    }
    private var menuBarRightClickAction: MenuBarRightClickAction {
        get { preferences.menuBarRightClickAction }
        set { preferences.menuBarRightClickAction = newValue }
    }
    private var menuBarReverseMouseButtons: Bool {
        get { preferences.menuBarReverseMouseButtons }
        set { preferences.menuBarReverseMouseButtons = newValue }
    }
    private var menuBarStatusItemWidthAdjustmentSession = MenuBarStatusItemWidthAdjustmentSession()
    private lazy var menuBarWidthAdjustmentCoalescer = MenuBarWidthDisplayCoalescer { [weak self] value in
        self?.applyMenuBarWidthAdjustmentFrame(value)
    }
    private var menuBarStatusItemWidthAdjustment: Double {
        menuBarStatusItemWidthAdjustmentSession.transientValue
            ?? preferences.menuBarStatusItemWidthAdjustment
    }
    private var menuBarStatusItemPhysicalWidthAdjustment: Double {
        menuBarStatusItemWidthAdjustment + AppPreferences.menuBarStatusItemWidthBaseline
    }

    init(
        repository: CCSwitchRepository = CCSwitchRepository(),
        officialQuotaClient: OfficialQuotaClient = OfficialQuotaClient(),
        updateService: UpdateService? = nil,
        launchAtLoginService: LaunchAtLoginService = SystemLaunchAtLoginService(),
        launchWithChatGPTService: LaunchWithChatGPTService = SystemLaunchWithChatGPTService()
    ) {
        self.ccSwitchRepository = repository
        self.officialQuotaClient = officialQuotaClient
        self.launchAtLoginController = LaunchAtLoginController(service: launchAtLoginService)
        self.launchWithChatGPTController = LaunchWithChatGPTController(service: launchWithChatGPTService)
        self.updateService = updateService ?? UpdateService(
            releaseFetcher: DevelopmentReleaseFixture.releaseFetcher(),
            updateChannel: preferences.updateChannel,
            ignoredVersionStore: UserDefaultsUpdateVersionIgnoreStore()
        )
        super.init()
        notificationCoordinator.onPermissionStateChanged = { [weak self] state in
            guard let self else { return }
            let previous = self.lastNotificationPermissionState
            self.lastNotificationPermissionState = state
            guard state == .denied || previous == .denied else { return }
            DispatchQueue.main.async {
                self.dashboardComposition.refreshNotificationsPage()
            }
        }
        notificationCoordinator.onOpenAgent = { [weak self] agent in
            guard let self else { return }
            DispatchQueue.main.async {
                if let client = agent.assistantClient {
                    self.currentAgentOpener.open(client: client)
                }
            }
        }
        reloadCurrentProviderNameCache()
        self.updateService.onStateChange = { [weak self] _ in
            guard let self else { return }
            let applyUpdateState = { [weak self] in
                guard let self else { return }
                self.dashboardComposition.refreshUpdateState()
                self.refreshStatusItemMenuInput()
            }
            if Thread.isMainThread { applyUpdateState() }
            else { DispatchQueue.main.async(execute: applyUpdateState) }
        }
        aggregationRepository = CCSwitchAggregationRepository(repository: repository)
        databaseWatcher = CCSwitchDatabaseWatcher(
            databaseURL: repository.databaseURL,
            stateURL: aggregationRepository.stateURL,
            onChange: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let appType = self.activeClient.appType
                    // Publish metadata asynchronously; the menu only reads the cache.
                    self.reloadCurrentProviderNameCache(appType: appType)
                    self.refreshStatusItemMenuInput()
                }
                SwitchLog.write("refresh triggered; origin=file-watcher; force=false", level: .debug, category: "refresh")
                self?.refresh(reason: .databaseChanged)
                self?.refreshMonitoredQuickSwitchSummaries(force: false, configurationChanged: true)
            }
        )
        providerRefreshCoordinator = ProviderRefreshCoordinator(
            repository: repository,
            officialQuotaClient: officialQuotaClient,
            balanceAPIClient: balanceAPIClient,
            balanceProgressStore: balanceProgressStore,
            queue: DispatchQueue(label: "local.balancebar.provider-refresh"),
            actions: ProviderRefreshActions(
                currentProvider: { [weak self] client in
                    self?.ccSwitchRepository.loadCurrent(appType: client.appType)
                },
                isActiveClient: { [weak self] client in
                    self?.activeClient == client
                },
                render: { [weak self] snapshot in self?.render(snapshot) },
                storeClientSnapshot: { [weak self] client, providerID, snapshot in
                    self?.clientSnapshots[client] = (providerID, snapshot)
                },
                quickSwitchSummaryChanged: { [weak self] providerID in
                    self?.publishQuickSwitchSummary(providerID: providerID)
                },
                notificationSnapshot: { [weak self] client, providerID, snapshot in
                    guard let self else { return }
                    self.notificationCoordinator.process(
                        snapshot: snapshot,
                        agent: Self.notificationAgent(for: client),
                        providerID: providerID
                    )
                },
                aggregationChanged: { [weak self] displays, blocked in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.aggregationDisplays != displays || self.aggregationQuickSwitchBlocked != blocked else { return }
                        let previousDefault = self.aggregationDisplays.first(where: { $0.entry.role == .default })
                        let dashboardChanged = self.aggregationDisplays.map { ($0.identity, $0.snapshot) }.elementsEqual(
                            displays.map { ($0.identity, $0.snapshot) }, by: { $0.0 == $1.0 && $0.1 == $1.1 }) == false
                        self.aggregationDisplays = displays
                        self.aggregationQuickSwitchBlocked = blocked
                        if self.activeClient == .codex {
                            if previousDefault != displays.first(where: { $0.entry.role == .default }) {
                                self.updateStatusItem(for: self.snapshot, refreshDashboard: false)
                            } else { self.refreshStatusItemMenuInput() }
                            if dashboardChanged {
                                self.updateDashboard(for: self.snapshot, refreshDate: self.refreshDate(for: self.snapshot))
                            }
                        }
                    }
                },
                ownedRender: { [weak self] providerID, snapshot in self?.render(snapshot, providerID: providerID) }
            )
        )
        providerSwitchCoordinator = ProviderSwitchCoordinator(
            repository: repository,
            aggregationRepository: aggregationRepository,
            actions: ProviderSwitchActions(
                changed: { [weak self] in
                    guard let self else { return }
                    self.providerRefreshCoordinator.resetCadence()
                    self.lastProviderID = nil
                    DispatchQueue.main.async {
                        self.refreshStatusItemMenuInput()
                    }
                    self.refresh(reason: .providerChanged)
                },
                failed: { [weak self] message in
                    self?.render(.error(message))
                }
            )
        )
        activityCoordinator = ActivityCoordinator(
            actions: ActivityCoordinatorActions(
                activeClient: { [weak self] in self?.activeClient ?? .codex },
                claudeProcessAvailable: { [weak self] in self?.isClaudeProcessAvailable ?? false },
                grokProcessAvailable: { [weak self] in self?.isGrokProcessAvailable ?? false },
                setClaudeProcessAvailable: { [weak self] available in
                    guard let self else { return }
                    if self.isClaudeProcessAvailable != available {
                        self.isClaudeProcessAvailable = available
                        SwitchLog.write("claude process availability changed; running=\(available)")
                    }
                },
                setGrokProcessAvailable: { [weak self] available in
                    guard let self else { return }
                    if self.isGrokProcessAvailable != available {
                        self.isGrokProcessAvailable = available
                        SwitchLog.write("grok process availability changed; running=\(available)")
                    }
                },
                setActiveClient: { [weak self] client in self?.setActiveClient(client) },
                setCodexTaskRunning: { [weak self] running in self?.setCodexTaskRunning(running) },
                setClaudeTaskRunning: { [weak self] running in self?.setClaudeTaskRunning(running) },
                setGrokTaskRunning: { [weak self] running in self?.setGrokTaskRunning(running) },
                resetActivityRefreshState: { [weak self] in self?.resetActivityRefreshState() },
                observeCodexActivity: { [weak self] update in self?.observeCodexActivity(update) },
                observeClaudeActivity: { [weak self] update in self?.observeClaudeActivity(update) },
                observeGrokActivity: { [weak self] update in self?.observeGrokActivity(update) }
            )
        )
        statusItemController = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: { [weak self] in
                    self?.performManualRefresh(source: "menu")
                },
                openDashboard: { [weak self] in
                    self?.openDashboard()
                },
                openChatGPT: { [weak self] in
                    self?.openCurrentAgent()
                },
                openCCSwitch: { [weak self] in
                    self?.openCCSwitch()
                },
                quit: { NSApp.terminate(nil) },
                switchProvider: { [weak self] providerID in
                    self?.switchProvider(providerID)
                },
                openProviderWebsite: { [weak self] in
                    self?.openProviderWebsite()
                },
                openStatusLink: { url in
                    NSWorkspace.shared.open(url)
                },
                iconChanged: { [weak self] image in
                    guard let self else { return }
                    self.dashboardComposition.refreshMenuBarPage(snapshot: self.snapshot)
                },
                frameImageChanged: { [weak self] image in
                    self?.dashboardComposition.updateMenuBarPreviewIcon(image)
                },
                animationStateChanged: { [weak self] active in
                    guard let self else { return }
                    self.dashboardComposition.updateMenuBarPreviewAnimation(
                        active: active,
                        iconImage: self.statusItemController?.iconImage
                    )
                },
                claudeAnimationStateChanged: { [weak self] active, iconImage, spriteImage in
                    self?.dashboardComposition.updateClaudeMenuBarPreviewAnimation(
                        active: active,
                        iconImage: iconImage,
                        spriteImage: spriteImage
                    )
                },
                grokAnimationStateChanged: { [weak self] active, iconImage, spriteImage in
                    self?.dashboardComposition.updateGrokMenuBarPreviewAnimation(
                        active: active,
                        iconImage: iconImage,
                        spriteImage: spriteImage
                    )
                },
                animationFallbackChanged: { [weak self] active in
                    self?.dashboardComposition.updateMenuBarAnimationFallback(active: active)
                },
                visibilityChanged: { [weak self] _ in
                    guard let self else { return }
                    self.dashboardComposition.refreshMenuBarPage(snapshot: self.snapshot)
                }
            ),
            codexAnimationBackend: MenuBarCodexAnimationBackend(
                mode: preferences.menuBarAnimationMode
            ),
            animationFrameRate: preferences.menuBarAnimationFrameRate
        )
    }

    private func makeStatusItemMenuInput() -> StatusItemController.MenuInput {
        let isOfficialOpenAICodex = activeClient == .codex && currentProviderIsOfficialCache
        let accountProfile = isOfficialOpenAICodex ? currentAccountProfileCache : nil
        let openAIAccount = OpenAIAccountPresentation.current(
            activeClient: activeClient,
            providerIsOfficial: isOfficialOpenAICodex,
            email: accountProfile?.email,
            subscription: OpenAISubscriptionTier(planType: accountProfile?.planType)
        )
        let directProviderID = clientSnapshots[activeClient]?.providerID ?? lastProviderID
            ?? providerChoicesCache.first(where: \.isCurrent)?.id
        let directProviderNotes = aggregationDisplays.isEmpty || activeClient != .codex
            ? directProviderID.flatMap { providerNotesCache[activeClient.appType]?[$0] }.map { [$0] } ?? [] : []
        return StatusItemController.MenuInput(
            choices: providerChoicesCache,
            quickSwitchSummaries: quickSwitchSummariesSnapshot(),
            activeClient: activeClient,
            openAIAccount: openAIAccount,
            statusLinks: statusLinks,
            showQuickSwitchMenu: showQuickSwitchMenu,
            showOpenChatGPTMenu: showOpenChatGPTMenu,
            showOpenCCSwitchMenu: showOpenCCSwitchMenu,
            showStatusMenu: showStatusMenu,
            directProviderNotes: directProviderNotes,
            directProviderID: directProviderID,
            directProviderIsOfficial: isOfficialOpenAICodex,
            lunaReserveDisplayMode: LunaReserveUserFacing.isCurrentlyEnabled
                ? preferences.menuLunaReserveDisplayMode
                : .disabled,
            lunaReserveHideExhaustedQuota: LunaReserveUserFacing.isCurrentlyEnabled
                && preferences.menuLunaReserveHideExhaustedQuota,
            bankedResetDisplayMode: preferences.menuBankedResetDisplayMode,
            showsAvailableUpdateBadge: showsAvailableUpdateBadge,
            aggregatedProviders: activeClient == .codex ? aggregationDisplays : [],
            aggregationQuickSwitchBlocked: activeClient == .codex && aggregationQuickSwitchBlocked
        )
    }

    private var showsAvailableUpdateBadge: Bool {
        if case .available = updateService.state {
            return true
        }
        return false
    }

    private func currentProviderName() -> String {
        currentProviderNameCache
    }

    /// Always read provider metadata in the background. Menus and search use
    /// published values; the reader discards obsolete completion generations.
    private func reloadCurrentProviderNameCache(appType: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reloadCurrentProviderNameCache(appType: appType) }
            return
        }
        let resolvedAppType = appType ?? activeClient.appType
        providerMetadataReader.reload(appType: resolvedAppType,
            includeSources: aggregationDisplays.isEmpty || activeClient != .codex) { [weak self] value in
            guard let self, self.activeClient.appType == resolvedAppType else { return }
            var changed = self.providerChoicesCache != value.choices
                || self.currentProviderIsOfficialCache != (value.current?.isOfficial == true)
            self.providerChoicesCache = value.choices
            if let sources = value.sources {
                let notes = Dictionary(uniqueKeysWithValues: sources.compactMap { source -> (String, String)? in
                    guard let note = source.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
                    return (source.id, note)
                })
                changed = changed || self.providerNotesCache[resolvedAppType] != notes
                self.providerNotesCache[resolvedAppType] = notes
            }
            self.currentProviderNameCache = value.choices.first(where: \.isCurrent)?.name ?? tr(.keyAppNotFound2)
            self.currentProviderIsOfficialCache = value.current?.isOfficial == true
            self.currentAccountProfileCache = value.current?.isOfficial == true && resolvedAppType == "codex"
                ? self.officialQuotaClient.codexAccountProfile() : nil
            self.refreshStatusItemMenuInput()
            if changed { self.updateDashboard(for: self.snapshot, refreshDate: self.refreshDate(for: self.snapshot)) }
        }
    }

    private func quickSwitchSummariesSnapshot() -> [String: String] {
        providerRefreshCoordinator?.quickSwitchSummariesSnapshot(
            preferredQuotaWindow: menuBarQuotaWindowPreference, client: activeClient
        ) ?? [:]
    }

    private func publishQuickSwitchSummary(providerID: String) {
        SwitchLog.write(
            "quick-switch balance changed; summary_updated=true",
            category: "balance"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItemController.updateMenu(input: self.makeStatusItemMenuInput())
            self.updateDashboard(for: self.snapshot, refreshDate: self.refreshDate(for: self.snapshot))
        }
    }

    private func makeStatusItemSettings() -> StatusItemController.MenuBarSettings {
        StatusItemController.MenuBarSettings(
            showIcon: showMenuBarIcon,
            showAmount: showMenuBarAmount,
            showReset: showMenuBarReset,
            horizontalPadding: menuBarHorizontalPadding,
            keepMenuOpenAfterRefresh: keepMenuOpenAfterRefresh,
            iconDisplayMode: menuBarIconDisplayMode,
            iconDisplayDelay: menuBarIconDisplayDelay,
            rightClickAction: menuBarRightClickAction,
            reverseMouseButtons: menuBarReverseMouseButtons,
            iconOffsetX: CGFloat(menuBarIconOffsetX),
            iconOffsetY: CGFloat(menuBarIconOffsetY),
            amountOffsetX: CGFloat(menuBarAmountOffsetX),
            amountOffsetY: CGFloat(menuBarAmountOffsetY),
            widthAdjustment: CGFloat(menuBarStatusItemPhysicalWidthAdjustment),
            fontSize: CGFloat(menuBarFontSize),
            iconSize: preferences.menuBarIconSize,
            quotaWindowPreference: menuBarQuotaWindowPreference,
            quotaResetDisplayMode: menuBarQuotaResetDisplayMode,
            autoSwitchLunaReserve: LunaReserveUserFacing.isCurrentlyEnabled
                && preferences.menuBarAutoSwitchLunaReserve,
            lunaReserveResetTimeMode: preferences.menuBarLunaReserveResetTimeMode,
            quotaProgressColorConfiguration: preferences.quotaProgressColorConfiguration,
            showQuotaProgressBar: preferences.showQuotaProgressBar,
            showBankedReset: preferences.showBankedReset,
            displayTimeZone: preferences.effectiveDisplayTimeZone
        )
    }

    private func updateStatusItemActivity(layout: Bool = true) {
        statusItemController.updateActivity(
            activeClient: activeClient,
            codexTaskRunning: isCodexTaskRunning,
            claudeTaskRunning: isClaudeTaskRunning,
            grokTaskRunning: isGrokTaskRunning,
            animationEnabled: animateCodexActivity,
            layout: layout
        )
    }

    private func updateStatusItem(
        for snapshot: Snapshot,
        refreshDashboard: Bool = true,
        deferMenuRebuild: Bool = false
    ) {
        let display = activeClient == .codex ? aggregationDisplays.first(where: { $0.entry.role == .default }) : nil
        statusItemController.update(
            snapshot: display?.snapshot ?? snapshot,
            refreshDate: display?.fetchedAt ?? refreshDate(for: snapshot),
            menuInput: makeStatusItemMenuInput(),
            settings: makeStatusItemSettings(),
            deferMenuRebuild: deferMenuRebuild
        )
        if refreshDashboard {
            refreshDashboardMenuBarPage()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard lifecycle.beginStart() else { return }
        if AggregationOverviewScrollView.diagnosticsEnabled {
            let sha = Bundle.main.object(forInfoDictionaryKey: "BalanceBarBuildSHA") as? String ?? "unknown"
            SwitchLog.write("Dev artifact; path=\(Bundle.main.bundlePath); pid=\(ProcessInfo.processInfo.processIdentifier); build_sha=\(sha)", category: "ui.aggregation")
        }
        if let iconURL = Bundle.main.url(forResource: "BalanceBar", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        observeDisplayTimeZone()
        configureApplicationMenu()
        NSApp.appearance = nil
        dashboardComposition.start()
        let harnessPresented = dashboardAccessoryHarness.presentIfRequested()
        let pendingRestore = DashboardRestoreStore.peek()
        let initialPresentation = InitialLaunchPresentation.resolve(
            silentLaunch: preferences.silentLaunch,
            pendingDashboardRestore: pendingRestore != nil
        )
        let shouldShowDashboard = initialPresentation == .dashboard && !harnessPresented
        let regularPolicyApplied: Bool
        if shouldShowDashboard || harnessPresented {
            regularPolicyApplied = AutomatedTestHost.isRunning
                ? NSApp.setActivationPolicy(.accessory)
                : NSApp.setActivationPolicy(.regular)
            if shouldShowDashboard {
                showDashboard(restore: pendingRestore)
            }
        } else {
            regularPolicyApplied = NSApp.setActivationPolicy(.accessory)
        }
        statusItemController.start(
            snapshot: snapshot,
            refreshDate: refreshDate(for: snapshot),
            menuInput: makeStatusItemMenuInput(),
            settings: makeStatusItemSettings()
        )
        checkForBackgroundUpdate()
        configureUpdateCheckTimer()
        updateStatusItemActivity()
        databaseWatcher.start()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ccSwitchLifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: nil) { [weak self] notification in
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.bundleIdentifier == "com.ccswitch.desktop" else { return }
                    self?.refresh(reason: .configurationChanged)
                })
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        SwitchLog.startSession()
        SwitchLog.write(
            "session started; version=\(version); os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            category: "lifecycle"
        )
        SwitchLog.write(
            "status chain startup; initial_presentation=\(initialPresentation); activation_policy=\(String(describing: NSApp.activationPolicy())); policy_call_result=\(regularPolicyApplied); \(statusItemController.startupDiagnostic)",
            category: "ui.status-item"
        )
        SwitchLog.write(
            "preferences; language=\(AppLanguage.selected.rawValue); provider_poll=\(providerPollInterval)s; activity_poll=\(activityPollInterval)s; active_refresh=\(codexUsageRefreshInterval)s; trailing_refresh=\(postCodexRefreshDuration)s",
            level: .debug,
            category: "configuration"
        )
        SwitchLog.write(
            "database watchers started; count=\(databaseWatcher.startCount)",
            category: "database"
        )
        refresh(reason: .initial)
        scheduleStartupAggregationReconciliation()
        refreshMonitoredQuickSwitchSummaries(force: true, extraClients: [.claude])
        providerRefreshCoordinator.prefetchCurrentBalance(for: .claude)
        activityCoordinator.start(interval: activityPollInterval)
        activityCoordinator.pollNow()
        // The file watcher handles normal CC Switch writes. This inexpensive
        // read is a fallback for a missed filesystem notification.
        configureRefreshTimers()
    }

    /// CC Switch can finish attaching its proxy stack just after BalanceBar's
    /// first read. Recheck once after launch so a transient default-only read
    /// cannot leave the menu stuck on one provider until manual refresh.
    private func scheduleStartupAggregationReconciliation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.activeClient == .codex else { return }
            guard case .active = self.aggregationRepository.load() else { return }
            SwitchLog.write(
                "startup aggregation reconciliation; source=delayed-launch-read",
                level: .debug,
                category: "refresh.aggregation"
            )
            self.refresh(reason: .configurationChanged)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard lifecycle.beginTerminate() else { return }
        displayTimeZoneObservers.forEach(NotificationCenter.default.removeObserver)
        displayTimeZoneObservers.removeAll()
        SwitchLog.write("session terminating", category: "lifecycle")
        timer?.invalidate()
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        activityCoordinator.stop()
        menuBarWidthAdjustmentCoalescer.cancel()
        menuBarStatusItemWidthAdjustmentSession.cancel()
        dashboardAccessoryHarness.teardown()
        dashboardComposition.teardown()
        statusItemController.teardown()
        databaseWatcher.stop()
        ccSwitchLifecycleObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        ccSwitchLifecycleObservers.removeAll()
        providerRefreshCoordinator.stopAggregation()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        dashboardComposition.refreshLaunchAtLogin()
        dashboardComposition.refreshLaunchWithChatGPT()
        notificationCoordinator.refreshPermission()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDashboard() }
        return true
    }

    @objc private func dashboardManualRefresh() {
        performManualRefresh(source: "dashboard")
    }

    private func performManualRefresh(source: String) {
        if let manualRefreshActionForTesting {
            manualRefreshActionForTesting()
            return
        }
        SwitchLog.write(
            "manual refresh requested; source=\(source); client=\(activeClient.rawValue)",
            category: "refresh"
        )
        refreshStatusItemMenuInput()
        refresh(reason: .manual)
        providerRefreshCoordinator.refreshQuickSwitchSummaries(force: true, for: activeClient)
    }

    private func refreshStatusItemMenuInput(deferRebuild: Bool = false) {
        guard let statusItemController else { return }
        statusItemController.updateMenu(
            input: makeStatusItemMenuInput(),
            deferRebuild: deferRebuild
        )
    }

    private func switchProvider(_ providerID: String) {
        guard activeClient != .grok else { return }
        let appType = activeClient.appType
        let providerName = ccSwitchRepository.loadChoices(appType: appType)
            .first(where: { $0.id == providerID })?.name ?? providerID
        providerSwitchCoordinator.switchProvider(
            providerID: providerID,
            appType: appType,
            providerName: providerName
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    deinit {
        displayTimeZoneObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func observeDisplayTimeZone() {
        guard displayTimeZoneObservers.isEmpty else { return }
        let center = NotificationCenter.default
        displayTimeZoneObservers.append(center.addObserver(
            forName: AppPreferences.displayTimeZoneDidChange, object: preferences, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshDisplayTimeZone() }
        })
        displayTimeZoneObservers.append(center.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.preferences.displayTimeZoneSelection == .system else { return }
            self.refreshDisplayTimeZone()
        })
    }

    /// Reformat the existing data without calling a refresh coordinator.
    private func refreshDisplayTimeZone() {
        updateStatusItem(for: snapshot, refreshDashboard: false)
        dashboardProviderPageRevision &+= 1
        dashboardComposition.refreshDisplayTimeZone(
            snapshot: snapshot, refreshDate: refreshDate(for: snapshot), revision: dashboardProviderPageRevision
        )
    }

    private func applyLanguage(_ language: AppLanguage) {
        let applied = DashboardLanguageChange.apply(
            language,
            currentlySelected: AppLanguage.selected,
            gate: languageChangeGate
        ) { selected in
            SwitchLog.write(
                "language changed; value=\(selected.rawValue)",
                category: "configuration"
            )
            AppLanguage.selected = selected
        }
        guard applied else { return }
        configureApplicationMenu()
        // Recreate status-menu labels immediately after changing the selected
        // language; the existing cards may otherwise retain cached text.
        refreshStatusItemMenuInput()
        rebuildDashboardForLanguageChange()
        render(snapshot)
        refresh(reason: .configurationChanged)
        providerRefreshCoordinator.refreshQuickSwitchSummaries(force: true, for: activeClient)
        languageChangeGate.endIgnoringCallbacksAfterCurrentRunLoopTurns()
    }

    private func configureApplicationMenu() {
        let configuration = ApplicationMenuConfiguration.make()
        NSApp.windowsMenu = configuration.windowMenu
        NSApp.mainMenu = configuration.mainMenu
    }

    private func openSystemMenuBarSettings() {
        let opened = NSWorkspace.shared.open(
            DashboardMenuBarPage.systemMenuBarSettingsURL
        )
        if !opened {
            SwitchLog.write(
                "failed to open system menu bar settings",
                level: .warning,
                category: "ui.dashboard"
            )
        }
    }

    @objc private func openCCSwitch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ccswitch.desktop") else { return }
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.ccswitch.desktop"
        ).first {
            NSApp.yieldActivation(to: app)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    private func openCurrentAgent() {
        currentAgentOpener.open(client: activeClient)
    }

    private func openChatGPTApplication() {
        let applicationURLs: [URL] = ChatGPTApplicationIdentity.bundleIdentifiers.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        } + [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT Classic.app")
        ]
        guard let url = applicationURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            SwitchLog.write(
                "open ChatGPT failed; reason=application-not-found",
                level: .warning,
                category: "ui.menu"
            )
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                SwitchLog.write(
                    "open ChatGPT failed; error_category=workspace_open",
                    level: .warning,
                    category: "ui.menu"
                )
            } else {
                SwitchLog.write(
                    "ChatGPT opened; success=true",
                    category: "ui.menu"
                )
            }
        }
    }

    @objc private func openProviderWebsite() {
        guard let activeProviderWebsite else { return }
        NSWorkspace.shared.open(activeProviderWebsite)
    }

    private func openStatusLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func handleDashboardToggle(identifier: String, enabled: Bool) {
        SwitchLog.write(
            "preference changed; key=\(identifier); enabled=\(enabled)",
            category: "configuration"
        )
        switch identifier {
        case "showMenuBarIcon":
            if !enabled && !showMenuBarAmount {
                dashboardComposition.restoreRequiredMenuBarToggle(identifier: identifier)
                return
            }
            showMenuBarIcon = enabled
            updateStatusItem(for: snapshot, refreshDashboard: false)
            refreshDashboardMenuBarPage()
        case "showMenuBarAmount":
            if !enabled && !showMenuBarIcon {
                dashboardComposition.restoreRequiredMenuBarToggle(identifier: identifier)
                return
            }
            showMenuBarAmount = enabled
            updateStatusItem(for: snapshot, refreshDashboard: false)
            refreshDashboardMenuBarPage()
        case "showMenuBarReset":
            showMenuBarReset = enabled
            updateStatusItem(for: snapshot, refreshDashboard: false)
            refreshDashboardMenuBarPage()
        case AppPreferences.showQuotaProgressBarKey:
            preferences.showQuotaProgressBar = enabled
            updateStatusItem(for: snapshot, refreshDashboard: false)
            updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
            dashboardComposition.refreshMenuPage()
        case AppPreferences.showBankedResetKey:
            preferences.showBankedReset = enabled
            updateStatusItem(for: snapshot, refreshDashboard: false)
            dashboardComposition.refreshMenuPage()
        case AppPreferences.menuLunaReserveHideExhaustedQuotaKey:
            preferences.menuLunaReserveHideExhaustedQuota = enabled
            refreshStatusItemMenuInput()
        case AppPreferences.menuBarAutoSwitchLunaReserveKey:
            preferences.menuBarAutoSwitchLunaReserve = enabled
            updateStatusItem(for: snapshot, refreshDashboard: false)
            refreshDashboardMenuBarPage()
        case "showQuickSwitchMenu":
            showQuickSwitchMenu = enabled
            render(snapshot)
        case "showOpenCCSwitchMenu":
            showOpenCCSwitchMenu = enabled
            render(snapshot)
        case "showOpenChatGPTMenu":
            showOpenChatGPTMenu = enabled
            render(snapshot)
        case "showStatusMenu":
            showStatusMenu = enabled
            render(snapshot)
            if dashboardSection == .menu {
                dashboardComposition.updateMenuStatusVisibility(enabled, animated: true)
            }
        case "keepMenuOpenAfterRefresh":
            keepMenuOpenAfterRefresh = enabled
        case AppPreferences.silentLaunchKey:
            preferences.silentLaunch = enabled
        case AppPreferences.menuBarReverseMouseButtonsKey:
            menuBarReverseMouseButtons = enabled
            updateStatusItem(for: snapshot)
        case "animateCodexActivity":
            animateCodexActivity = enabled
            setCodexTaskRunning(isCodexTaskRunning, force: true)
            refreshDashboardMenuBarPage()
        default:
            break
        }
    }

    private func handleLaunchAtLoginAction(enabled: Bool) {
        applyLaunchAtLogin(enabled: enabled)
    }

    private func applyLaunchAtLogin(enabled: Bool) {
        let outcome = launchAtLoginController.setEnabled(enabled)
        dashboardComposition.refreshLaunchAtLogin(outcome.state)
        guard let error = outcome.error else { return }
        SwitchLog.write(
            "launch at login operation threw; requested_enabled=\(enabled); observed_status=\(String(describing: outcome.state.status)); error=\(error)",
            level: .error,
            category: "configuration"
        )
    }

    private func handleLaunchWithChatGPTAction(enabled: Bool) {
        applyLaunchWithChatGPT(enabled: enabled)
    }

    private func applyLaunchWithChatGPT(enabled: Bool) {
        let outcome = launchWithChatGPTController.setEnabled(enabled)
        dashboardComposition.refreshLaunchWithChatGPT(outcome.state)
        guard let error = outcome.error else { return }
        SwitchLog.write(
            "launch with ChatGPT operation threw; requested_enabled=\(enabled); observed_status=\(String(describing: outcome.state.status)); error=\(error)",
            level: .error,
            category: "configuration"
        )
    }

    private func openLaunchWithChatGPTSettings() {
        launchWithChatGPTController.openSystemSettingsLoginItems()
    }

    private func handleDashboardBalanceDisplayThresholdChanged(_ value: Double) {
        let normalized = AppPreferences.normalizedBalanceDisplayThreshold(value)
        preferences.balanceDisplayThreshold = normalized
        let formatted = String(format: "%.2f", normalized)
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.balanceDisplayThresholdKey); value=\(formatted)",
            category: "configuration"
        )
        refresh(reason: .configurationChanged)
    }

    private func handleQuotaProgressColorConfigurationChanged(_ configuration: QuotaProgressColorConfiguration) {
        preferences.quotaProgressColorConfiguration = configuration
        updateStatusItem(for: snapshot, refreshDashboard: false)
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
    }

    private func handleDashboardQuotaWindowPreferenceChanged(
        _ preference: OfficialQuotaWindowPreference
    ) {
        menuBarQuotaWindowPreference = preference
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuBarQuotaWindowPreferenceKey); value=\(preference.rawValue)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot)
    }

    private func handleDashboardMenuBarIconDisplayModeChanged(
        _ mode: MenuBarIconDisplayMode
    ) {
        menuBarIconDisplayMode = mode
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuBarIconDisplayModeKey); value=\(mode.rawValue)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot)
    }

    private func handleDashboardMenuBarIconDisplayDelayChanged(
        _ delay: MenuBarIconDisplayDelay
    ) {
        menuBarIconDisplayDelay = delay
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuBarIconDisplayDelayKey); value=\(delay.rawValue)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot)
    }

    private func handleDashboardMenuBarRightClickActionChanged(
        _ action: MenuBarRightClickAction
    ) {
        menuBarRightClickAction = action
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuBarRightClickActionKey); value=\(action.rawValue)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot)
    }

    private func handleDashboardMenuBarAnimationModeChanged(
        _ mode: MenuBarAnimationMode
    ) {
        menuBarAnimationMode = mode
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuBarAnimationModeKey); value=\(mode.rawValue)",
            category: "configuration"
        )
        statusItemController.setCodexAnimationBackend(
            MenuBarCodexAnimationBackend(mode: mode)
        )
        refreshDashboardMenuBarPage()
    }

    private func handleDashboardMenuBarAnimationFrameRateChanged(_ fps: Int) {
        let clamped = MenuBarAnimationTiming.clampedFrameRate(fps)
        preferences.menuBarAnimationFrameRate = clamped
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuBarAnimationFrameRateKey); value=\(clamped)",
            category: "configuration"
        )
        statusItemController.setAnimationFrameRate(clamped)
        refreshDashboardMenuBarPage()
    }

    private func handleDashboardQuotaResetDisplayModeChanged(
        _ mode: OfficialQuotaResetDisplayMode
    ) {
        menuBarQuotaResetDisplayMode = mode
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuBarQuotaResetDisplayModeKey); value=\(mode.rawValue)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot)
    }

    private func handleDashboardLunaReserveResetTimeModeChanged(
        _ mode: LunaReserveResetTimeMode
    ) {
        preferences.menuBarLunaReserveResetTimeMode = mode
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuBarLunaReserveResetTimeModeKey); value=\(mode.rawValue)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot, refreshDashboard: false)
        refreshDashboardMenuBarPage()
    }

    private func handleDashboardLunaReserveDisplayModeChanged(
        _ mode: LunaReserveDisplayMode
    ) {
        preferences.menuLunaReserveDisplayMode = mode
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuLunaReserveDisplayModeKey); value=\(mode.rawValue)",
            category: "configuration"
        )
        refreshStatusItemMenuInput()
        dashboardComposition.refreshMenuPage()
    }

    private func handleDashboardBankedResetDisplayModeChanged(
        _ mode: CodexBankedResetDisplayMode
    ) {
        preferences.menuBankedResetDisplayMode = mode
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.menuBankedResetDisplayModeKey); value=\(mode.rawValue)",
            category: "configuration"
        )
        refreshStatusItemMenuInput()
        dashboardComposition.refreshMenuPage()
    }

    private func handleUpdateChannelChanged(_ channel: UpdateChannel) {
        preferences.updateChannel = channel
        updateService.updateChannel = channel
        updateService.checkForUpdatesIfNeeded(force: true)
        SwitchLog.write(
            "preference changed; key=\(AppPreferences.updateChannelKey); value=\(channel.rawValue)",
            category: "configuration"
        )
    }

    private func handleDashboardInterval(identifier: String, value: TimeInterval) {
        SwitchLog.write(
            "interval changed; key=\(identifier); value=\(value)s",
            category: "configuration"
        )
        var refreshTimers = false
        switch identifier {
        case "activityPollInterval":
            activityPollInterval = value
            refreshTimers = true
        case "codexUsageRefreshInterval":
            codexUsageRefreshInterval = value
        case "postCodexRefreshDuration":
            postCodexRefreshDuration = value
            let lifecycle = activityRefreshLifecycle(for: activeClient)
            if let anchor = lifecycle.trailingRefreshAnchor {
                postCodexRefreshDeadline = value > 0
                    ? anchor.addingTimeInterval(value)
                    : nil
            } else if !isCodexTaskRunning, postCodexRefreshDeadline != nil {
                postCodexRefreshDeadline = value > 0
                    ? Date().addingTimeInterval(value)
                    : nil
            }
        default: return
        }
        if refreshTimers {
            configureRefreshTimers()
        }
    }

    private func handleDashboardOffsetAdjust(identifier: String, delta: Int) {
        let pointDelta = Double(delta) * AppPreferences.menuBarOffsetStep
        switch identifier {
        case AppPreferences.menuBarIconOffsetXKey:
            preferences.menuBarIconOffsetX += pointDelta
        case AppPreferences.menuBarIconOffsetYKey:
            preferences.menuBarIconOffsetY += pointDelta
        case AppPreferences.menuBarAmountOffsetXKey:
            preferences.menuBarAmountOffsetX += pointDelta
        case AppPreferences.menuBarAmountOffsetYKey:
            preferences.menuBarAmountOffsetY += pointDelta
        default:
            return
        }
        SwitchLog.write(
            "preference changed; key=\(identifier); delta=\(delta) step; point_delta=\(pointDelta); icon_x=\(preferences.menuBarIconOffsetX); icon_y=\(preferences.menuBarIconOffsetY); amount_x=\(preferences.menuBarAmountOffsetX); amount_y=\(preferences.menuBarAmountOffsetY); width=\(preferences.menuBarStatusItemWidthAdjustment); width_physical=\(menuBarStatusItemPhysicalWidthAdjustment)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot)
    }

    private func handleDashboardOffsetValue(identifier: String, value: Double) {
        switch identifier {
        case AppPreferences.menuBarFontSizePresetKey:
            guard let preset = MenuBarFontSizePreset(segmentIndex: Int(value.rounded())) else {
                return
            }
            applyMenuBarFontSizePreset(preset)
        case AppPreferences.menuBarIconSizePresetKey:
            guard let preset = MenuBarIconSizePreset(segmentIndex: Int(value.rounded())) else {
                return
            }
            applyMenuBarIconSizePreset(preset)
        case AppPreferences.menuBarFontSizeKey:
            // Keep the numeric route for migration-era callers. The current
            // settings page sends the discrete preset key above.
            menuBarFontSize = value
            updateStatusItem(for: snapshot)
        case AppPreferences.menuBarIconOffsetYKey:
            preferences.menuBarIconOffsetY = value
            updateStatusItem(for: snapshot)
        case AppPreferences.menuBarAmountOffsetYKey:
            preferences.menuBarAmountOffsetY = value
            updateStatusItem(for: snapshot)
        case AppPreferences.menuBarStatusItemWidthAdjustmentKey:
            // NSSlider sends this action continuously. Keep the value transient:
            // UserDefaults and logging belong to the editing-ended path, not the
            // mouse-tracking hot path.
            let transientValue = menuBarStatusItemWidthAdjustmentSession.update(value)
            MenuBarWidthPerformance.measure("slider-action") {
                menuBarWidthAdjustmentCoalescer.submit(CGFloat(transientValue))
            }
        default:
            return
        }
    }

    private func applyMenuBarFontSizePreset(_ preset: MenuBarFontSizePreset) {
        guard preferences.menuBarFontSizePreset != preset else { return }
        preferences.menuBarFontSizePreset = preset
        statusItemController.updateFontSize(CGFloat(preset.primarySize))
        refreshDashboardMenuBarPage()
    }

    private func applyMenuBarIconSizePreset(_ preset: MenuBarIconSizePreset) {
        guard preferences.menuBarIconSizePreset != preset else { return }
        preferences.menuBarIconSizePreset = preset
        statusItemController.updateIconSize(preset.pointSize)
        refreshDashboardMenuBarPage()
    }

    private func handleDashboardOffsetValueEnded(identifier: String, value: Double) {
        guard identifier == AppPreferences.menuBarStatusItemWidthAdjustmentKey else {
            return
        }
        let appPreferences = preferences
        let finalValue = menuBarStatusItemWidthAdjustmentSession.finish(value) { finalValue in
            appPreferences.menuBarStatusItemWidthAdjustment = finalValue
        }
        menuBarWidthAdjustmentCoalescer.submit(CGFloat(finalValue))
        menuBarWidthAdjustmentCoalescer.flush()
        finishDashboardMenuBarWidthAdjustment(finalValue)
        SwitchLog.write(
            "preference changed; key=\(identifier); value=\(menuBarStatusItemWidthAdjustment); width_physical=\(menuBarStatusItemPhysicalWidthAdjustment)",
            category: "configuration"
        )
    }

    private func applyMenuBarWidthAdjustmentFrame(_ widthAdjustment: CGFloat) {
        let physicalWidthAdjustment = widthAdjustment
            + CGFloat(AppPreferences.menuBarStatusItemWidthBaseline)
        MenuBarWidthPerformance.measure("menu-bar-width-frame") {
            statusItemController.updateWidthAdjustment(physicalWidthAdjustment)
            refreshDashboardMenuBarWidthAdjustment(Double(widthAdjustment))
        }
    }

    private func handleDashboardOffsetReset(identifier: String) {
        switch identifier {
        case DashboardMenuBarPage.iconOffsetsResetIdentifier:
            preferences.menuBarIconOffsetX = 0
            preferences.menuBarIconOffsetY = 0
        case DashboardMenuBarPage.amountOffsetsResetIdentifier:
            preferences.menuBarAmountOffsetX = 0
            preferences.menuBarAmountOffsetY = 0
        default:
            return
        }
        SwitchLog.write(
            "preference reset; identifier=\(identifier); icon_x=\(preferences.menuBarIconOffsetX); icon_y=\(preferences.menuBarIconOffsetY); amount_x=\(preferences.menuBarAmountOffsetX); amount_y=\(preferences.menuBarAmountOffsetY); width=\(preferences.menuBarStatusItemWidthAdjustment); width_physical=\(menuBarStatusItemPhysicalWidthAdjustment)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot)
    }

    @objc private func dashboardMenuBarPaddingChanged(_ sender: NSSlider) {
        menuBarHorizontalPadding = CGFloat(sender.doubleValue)
        updateStatusItem(for: snapshot)
    }

    @objc private func openDashboard() {
        dashboardComposition.open()
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
    }

    private static func notificationAgent(for client: AssistantClient) -> BalanceNotificationAgent {
        switch client {
        case .codex: return .gpt
        case .claude: return .claude
        case .grok: return .grok
        }
    }

    var dashboardCompositionForTesting: DashboardCompositionController { dashboardComposition }
    var providerChoicesForTesting: [ProviderChoice] { providerChoicesCache }
    var manualRefreshActionForTesting: (() -> Void)?

    var backgroundUpdateTimerForTesting: Timer? { updateCheckTimer }

    func presentInitialDashboardForTesting() {
        dashboardComposition.start()
        let pendingRestore = DashboardRestoreStore.peek()
        if InitialLaunchPresentation.resolve(
            silentLaunch: preferences.silentLaunch,
            pendingDashboardRestore: pendingRestore != nil
        ) == .dashboard {
            showDashboard(restore: pendingRestore)
        }
    }

    func handleLaunchAtLoginActionForTesting(enabled: Bool) {
        handleLaunchAtLoginAction(enabled: enabled)
    }

    func handleLaunchWithChatGPTActionForTesting(enabled: Bool) {
        handleLaunchWithChatGPTAction(enabled: enabled)
    }

    private func showDashboard(restore: DashboardRestoreToken? = nil) {
        dashboardComposition.open(
            initialSection: restore?.section ?? .general,
            scrollOffsetY: restore.map { CGFloat($0.scrollOffsetY) }
        )
        if restore != nil {
            DashboardRestoreStore.clear()
        }
        if let restore {
            let offset = CGFloat(restore.scrollOffsetY)
            DispatchQueue.main.async { [weak self] in
                self?.dashboardComposition.restorePageScrollOffsetY(offset)
            }
        }
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
    }

    private func rebuildDashboardForLanguageChange() {
        dashboardComposition.rebuild()
        updateNotesWindowController.refreshForCurrentLanguage()
    }

    private func showUpdateNotes() {
        guard case .available(let current, _) = updateService.state,
              let release = updateService.availableReleaseForPresentation else { return }
        let releases = updateService.availableReleasesForPresentation
        showUpdateNotes(
            currentVersion: current,
            releases: releases.isEmpty ? [release] : releases
        )
    }

    private func showUpdateNotes(
        currentVersion: AppSemanticVersion,
        releases: [GitHubRelease]
    ) {
        updateNotesWindowController.show(currentVersion: currentVersion, releases: releases)
    }

    private func showDashboardSection(_ section: DashboardSection) {
        dashboardComposition.showSection(section)
    }

    private func clampDashboardScrollViewBounds() {
        dashboardComposition.clampScrollBounds()
    }

    private func showDashboardProvider(_ providerID: String) {
        dashboardComposition.showProvider(providerID)
    }

    private func refreshDashboardMenuBarPage() {
        dashboardComposition.refreshMenuBarPage(snapshot: snapshot)
    }

    private func refreshDashboardMenuBarWidthAdjustment(_ widthAdjustment: Double) {
        dashboardComposition.refreshMenuBarWidthAdjustment(
            widthAdjustment,
            horizontalPadding: menuBarHorizontalPadding
        )
    }

    private func finishDashboardMenuBarWidthAdjustment(_ widthAdjustment: Double) {
        dashboardComposition.finishMenuBarWidthAdjustment(
            widthAdjustment,
            horizontalPadding: menuBarHorizontalPadding
        )
    }

    private func refreshMonitoredQuickSwitchSummaries(
        force: Bool,
        extraClients: [AssistantClient] = [],
        configurationChanged: Bool = false
    ) {
        var seen = Set<AssistantClient>()
        for client in [activeClient] + extraClients where seen.insert(client).inserted {
            providerRefreshCoordinator.refreshQuickSwitchSummaries(force: force, for: client, configurationChanged: configurationChanged)
        }
        for target in notificationCoordinator.monitoredNotificationTargets()
        where seen.insert(target.client).inserted {
            providerRefreshCoordinator.refreshQuickSwitchSummaries(
                force: force,
                for: target.client,
                providerIDs: target.providerIDs,
                configurationChanged: configurationChanged
            )
        }
    }

    private func configureRefreshTimers() {
        timer?.invalidate()

        let providerTimer = Timer(timeInterval: providerPollInterval, repeats: true) { [weak self] _ in
            self?.refreshStatusItemMenuInput()
            self?.refresh(reason: .scheduled)
            self?.refreshMonitoredQuickSwitchSummaries(force: false)
        }
        timer = providerTimer
        RunLoop.main.add(providerTimer, forMode: .common)
        activityCoordinator.updateInterval(activityPollInterval)
    }

    static let backgroundUpdateCheckInterval: TimeInterval = 6 * 60 * 60

    private func checkForBackgroundUpdate() {
        if case .available = updateService.state {
            return
        }
        updateService.checkForUpdatesIfNeeded()
    }

    private func configureUpdateCheckTimer() {
        updateCheckTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.backgroundUpdateCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkForBackgroundUpdate()
        }
        updateCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resetActivityRefreshState() {
        codexActivityRefreshLifecycle.reset()
        claudeActivityRefreshLifecycle.reset()
        grokActivityRefreshLifecycle.reset()
        lastCodexUsageRefresh = nil
        postCodexRefreshDeadline = nil
    }

    private func activityRefreshLifecycle(for client: AssistantClient) -> ActivityRefreshLifecycle {
        switch client {
        case .codex:
            return codexActivityRefreshLifecycle
        case .claude:
            return claudeActivityRefreshLifecycle
        case .grok:
            return grokActivityRefreshLifecycle
        }
    }

    private func observeCodexActivity(_ update: ActivityLifecycleUpdate) {
        codexActivityRefreshLifecycle.apply(update)
        guard activeClient == .codex else { return }
        reconcileActivityRefreshWindow(for: .codex, observation: update.observation)
    }

    private func observeClaudeActivity(_ update: ActivityLifecycleUpdate) {
        claudeActivityRefreshLifecycle.apply(update)
        guard activeClient == .claude else { return }
        reconcileActivityRefreshWindow(for: .claude, observation: update.observation)
    }

    private func observeGrokActivity(_ update: ActivityLifecycleUpdate) {
        grokActivityRefreshLifecycle.apply(update)
        guard activeClient == .grok else { return }
        reconcileActivityRefreshWindow(for: .grok, observation: update.observation)
    }

    private func reconcileActivityRefreshWindow(
        for client: AssistantClient,
        observation: ActivityMonitorObservation
    ) {
        switch observation {
        case .active, .contextCompaction:
            // Active work and compaction cancel any potential end from an
            // earlier ambiguous-idle sample. Compaction itself remains
            // refresh-suspended until normal activity appears again.
            postCodexRefreshDeadline = nil
        case .ambiguousIdle, .hardTerminal:
            let lifecycle = activityRefreshLifecycle(for: client)
            guard let anchor = lifecycle.trailingRefreshAnchor else { return }
            establishPostCodexRefreshWindow(from: anchor)
        }
    }

    private func establishPostCodexRefreshWindow(from anchor: Date) {
        guard postCodexRefreshDuration > 0 else {
            postCodexRefreshDeadline = nil
            return
        }
        let candidate = anchor.addingTimeInterval(postCodexRefreshDuration)
        if let current = postCodexRefreshDeadline {
            postCodexRefreshDeadline = min(current, candidate)
        } else {
            postCodexRefreshDeadline = candidate
        }
    }

    private func setCodexTaskRunning(_ running: Bool, force: Bool = false) {
        let wasRunning = isCodexTaskRunning
        let stateChanged = running != wasRunning
        isCodexTaskRunning = running
        if stateChanged {
            SwitchLog.write("task state changed; client=codex; running=\(running)")
        }
        if activeClient == .codex {
            updateActiveUsageRefresh(
                running: running,
                wasRunning: wasRunning,
                client: .codex
            )
        }
        if force || stateChanged {
            updateStatusItemActivity()
        } else {
            // Feed each accepted monitor sample to the display policy so an
            // idle transition is confirmed by stable polling, without
            // changing the activity monitor's meaning or refresh cadence.
            statusItemController.observeCodexTaskSample(running)
        }
    }

    private func setClaudeTaskRunning(_ running: Bool, force: Bool = false) {
        let wasRunning = isClaudeTaskRunning
        let stateChanged = running != wasRunning
        isClaudeTaskRunning = running
        if stateChanged {
            SwitchLog.write("task state changed; client=claude; running=\(running)")
        }
        if activeClient == .claude {
            updateActiveUsageRefresh(
                running: running,
                wasRunning: wasRunning,
                client: .claude
            )
        }
        guard force || stateChanged else { return }
        updateStatusItemActivity()
    }

    private func setGrokTaskRunning(_ running: Bool, force: Bool = false) {
        let wasRunning = isGrokTaskRunning
        let stateChanged = running != wasRunning
        isGrokTaskRunning = running
        if stateChanged {
            SwitchLog.write("task state changed; client=grok; running=\(running)")
        }
        if activeClient == .grok {
            updateActiveUsageRefresh(
                running: running,
                wasRunning: wasRunning,
                client: .grok
            )
        }
        guard force || stateChanged else { return }
        updateStatusItemActivity()
    }

    private func updateActiveUsageRefresh(
        running: Bool,
        wasRunning: Bool,
        client: AssistantClient
    ) {
        let now = Date()
        let lifecycle = activityRefreshLifecycle(for: client)
        let resumed: Bool
        switch client {
        case .codex:
            resumed = codexActivityRefreshLifecycle.consumeImmediateResume()
        case .claude:
            resumed = claudeActivityRefreshLifecycle.consumeImmediateResume()
        case .grok:
            resumed = grokActivityRefreshLifecycle.consumeImmediateResume()
        }
        let inTrailingWindow = postCodexRefreshDeadline.map { now < $0 } ?? false
        let shouldRefreshUsage = ActivityRefreshPolicy.shouldRefreshUsage(
            taskRunning: running,
            wasTaskRunning: wasRunning,
            phase: lifecycle.phase,
            inTrailingWindow: inTrailingWindow
        )
        let shouldIssueRefresh = ActivityRefreshPolicy.shouldIssueRefresh(
            taskRunning: running,
            wasTaskRunning: wasRunning,
            phase: lifecycle.phase,
            inTrailingWindow: inTrailingWindow,
            now: now,
            lastRefresh: lastCodexUsageRefresh,
            refreshInterval: codexUsageRefreshInterval,
            resumed: resumed
        )
        if shouldIssueRefresh {
            lastCodexUsageRefresh = now
            refresh(reason: .activityUsage)
        } else if !shouldRefreshUsage {
            lastCodexUsageRefresh = nil
            postCodexRefreshDeadline = nil
            if !inTrailingWindow {
                switch client {
                case .codex:
                    codexActivityRefreshLifecycle.clearTrailingRefreshAnchor()
                case .claude:
                    claudeActivityRefreshLifecycle.clearTrailingRefreshAnchor()
                case .grok:
                    grokActivityRefreshLifecycle.clearTrailingRefreshAnchor()
                }
            }
        }
    }

    private func setActiveClient(_ client: AssistantClient) {
        guard client != activeClient else { return }
        activeClient = client
        snapshotProviderID = nil
        SwitchLog.write("active client changed; client=\(client.rawValue)")
        lastProviderID = nil
        providerRefreshCoordinator.resetCadence()
        lastCodexUsageRefresh = nil
        postCodexRefreshDeadline = nil
        let lifecycle = activityRefreshLifecycle(for: activeClient)
        if let anchor = lifecycle.trailingRefreshAnchor {
            establishPostCodexRefreshWindow(from: anchor)
        }
        // Never flash the generic ellipsis during a focus switch. Reuse the
        // last successful snapshot for this client while the live refresh runs.
        // Startup prefetch normally makes this available before the first switch.
        let currentProvider = ccSwitchRepository.loadCurrent(appType: client.appType)
        reloadCurrentProviderNameCache()
        let cached = clientSnapshots[client]
        let hasCachedSnapshot = cached.map { currentProvider?.id == $0.providerID } ?? false
        // A following cached render layouts icon+digits together. Skip the
        // extra layout inside updateActivity so one client switch pays for
        // layoutStatusItem once. Icon swap still happens.
        updateStatusItemActivity(layout: !hasCachedSnapshot)
        refreshStatusItemMenuInput(deferRebuild: true)
        if hasCachedSnapshot, let cached {
            lastProviderID = cached.providerID
            render(cached.snapshot, providerID: cached.providerID, immediately: true, deferMenuRebuild: true)
        }
        if client != .grok || currentProvider != nil {
            refresh(reason: .clientChanged)
        }
        // Identity-driven tab switches already have per-client snapshots and
        // startup/cadence quick-switch summaries. Skip the extra force fetch
        // on the click path; the 60s cadence still refreshes the dropdown.
        if dashboardIsVisible {
            refreshDashboardMenuBarPage()
        }
    }

    private func menuBarSnapshot(for snapshot: Snapshot) -> Snapshot {
        snapshot.menuBarSnapshot(
            preferredQuotaWindow: menuBarQuotaWindowPreference,
            automaticallyUseLunaReserve: LunaReserveUserFacing.isCurrentlyEnabled
                && preferences.menuBarAutoSwitchLunaReserve
        )
    }

    private func updateDashboard(for snapshot: Snapshot, refreshDate: Date?) {
        guard dashboardIsVisible else { return }
        dashboardProviderPageRevision &+= 1
        dashboardComposition.refreshMountedPage(
            snapshot: snapshot,
            refreshDate: refreshDate,
            revision: dashboardProviderPageRevision
        )
    }

    private func refresh(reason: BalanceRefreshReason) {
        let client = activeClient
        SwitchLog.write("provider refresh triggered; reason=\(reason); client=\(client.rawValue); force=\(reason.forcesStandardProviderBalance)",
            level: .debug, category: "refresh", throttleKey: "provider-refresh-\(reason)", minimumInterval: 1)
        providerRefreshCoordinator.performAsync { [weak self] in
            guard let self else { return }
            if client == .codex, self.providerRefreshCoordinator.refreshAggregation(
                reader: self.aggregationRepository, force: reason.forcesStandardProviderBalance) { return }
            let current: CCSwitchProvider?
            do { current = try self.ccSwitchRepository.loadCurrentChecked(appType: client.appType) }
            catch {
                SwitchLog.write("provider refresh deferred; reason=database_read_failed; sqlite_code=\((error as? CCSwitchReadError)?.sqliteCode ?? -1); client=\(client.rawValue)",
                    level: .warning, category: "provider.read")
                return
            }
            self.reloadCurrentProviderNameCache(appType: client.appType)
            guard let current else {
                SwitchLog.write(
                    "refresh failed; client=\(client.rawValue); current provider not found",
                    level: .error,
                    category: "provider"
                )
                self.render(.error(tr(.keyAppTheCurrentCcSwitchValueProviderWasNotFound, arguments: [String(describing: client.displayName)])))
                return
            }

            // The Provider name is local CC Switch state, so reflect it in the
            // dashboard immediately instead of waiting for the remote balance
            // request to finish.
            let switched = current.id != self.lastProviderID
            if switched {
                SwitchLog.write("provider observed; app=\(client.appType); source=database watcher/poll")
            }
            self.lastProviderID = current.id
            self.providerRefreshCoordinator.refreshStandardProvider(
                current: current,
                client: client,
                forceBalance: reason.forcesStandardProviderBalance,
                switched: switched
            )
        }
    }

    private func render(_ next: Snapshot, providerID: String? = nil, immediately: Bool = false, deferMenuRebuild: Bool = false) {
        let apply = {
            if let providerID { self.snapshotProviderID = providerID }
            else if next != self.snapshot { self.snapshotProviderID = nil }
            self.snapshot = next
            self.activeProviderWebsite = next.websiteURL
            if next.kind != .error, next.kind != .placeholder { self.lastSuccessfulRefresh = next.date }
            self.updateStatusItem(for: next, refreshDashboard: false, deferMenuRebuild: deferMenuRebuild)
            let refreshDate = self.refreshDate(for: next)
            self.updateDashboard(for: next, refreshDate: refreshDate)
        }
        if immediately, Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func refreshDate(for snapshot: Snapshot) -> Date? {
        if snapshot.kind == .error, !snapshot.provider.isEmpty {
            return snapshot.date
        }
        return lastSuccessfulRefresh ?? snapshot.date
    }

}

struct ApplicationMenuConfiguration {
    let mainMenu: NSMenu
    let windowMenu: NSMenu

    static func make() -> ApplicationMenuConfiguration {
        let mainMenu = NSMenu(title: "BalanceBar")

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "BalanceBar")
        applicationItem.submenu = applicationMenu
        applicationMenu.addItem(
            withTitle: tr(.keyAppAboutBalancebar),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let hideItem = applicationMenu.addItem(
            withTitle: tr(.keyAppHideBalancebar),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.keyEquivalentModifierMask = [.command]
        let hideOthers = applicationMenu.addItem(
            withTitle: tr(.keyAppHideOthers),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(
            withTitle: tr(.keyAppShowAll),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(
            withTitle: tr(.keyAppQuitBalancebar),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = NSApp
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr(.keyAppEdit))
        editItem.submenu = editMenu
        editMenu.autoenablesItems = true
        let undoItem = editMenu.addItem(
            withTitle: tr(.keyAppUndo),
            action: #selector(UndoManager.undo),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.command]
        let redoItem = editMenu.addItem(
            withTitle: tr(.keyAppRedo),
            action: #selector(UndoManager.redo),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        for (title, action, keyEquivalent) in [
            (tr(.keyAppCut), #selector(NSText.cut(_:)), "x"),
            (tr(.keyAppCopy), #selector(NSText.copy(_:)), "c"),
            (tr(.keyAppPaste), #selector(NSText.paste(_:)), "v"),
            (tr(.keyAppSelectAll), #selector(NSText.selectAll(_:)), "a")
        ] {
            let item = editMenu.addItem(
                withTitle: title,
                action: action,
                keyEquivalent: keyEquivalent
            )
            item.keyEquivalentModifierMask = [.command]
        }
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: tr(.keyAppWindow))
        windowMenu.autoenablesItems = true
        windowItem.submenu = windowMenu

        let closeItem = windowMenu.addItem(
            withTitle: tr(.keyAppCloseWindow),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = [.command]
        closeItem.target = nil

        let minimizeItem = windowMenu.addItem(
            withTitle: tr(.keyAppMinimize),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        minimizeItem.keyEquivalentModifierMask = [.command]
        minimizeItem.target = nil

        let zoomItem = windowMenu.addItem(
            withTitle: tr(.keyAppZoom),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        zoomItem.target = nil

        windowMenu.addItem(.separator())
        let arrangeItem = windowMenu.addItem(
            withTitle: tr(.keyAppBringAllToFront),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        arrangeItem.target = nil

        mainMenu.addItem(windowItem)
        return ApplicationMenuConfiguration(mainMenu: mainMenu, windowMenu: windowMenu)
    }
}

struct ApplicationLifecycleStats: Equatable {
    let startCount: Int
    let terminateCount: Int
}

/// Small, main-thread-owned lifecycle gate used by the composition root.
/// Keeping the gate independent makes the single-install/single-teardown
/// contract testable without starting AppKit's event loop.
final class ApplicationLifecycleState {
    private(set) var hasStarted = false
    private(set) var hasTerminated = false
    private(set) var startCount = 0
    private(set) var terminateCount = 0

    var stats: ApplicationLifecycleStats {
        ApplicationLifecycleStats(
            startCount: startCount,
            terminateCount: terminateCount
        )
    }

    func beginStart() -> Bool {
        guard !hasStarted, !hasTerminated else { return false }
        hasStarted = true
        startCount += 1
        return true
    }

    func beginTerminate() -> Bool {
        guard hasStarted, !hasTerminated else { return false }
        hasTerminated = true
        terminateCount += 1
        return true
    }
}

@main
enum BalanceBarMain {
    static func main() {
        if AutomatedTestHost.isRunning {
            // XCTest still needs the default run loop to attach. Switch to
            // accessory and yield key focus before any window is created so
            // launch does not steal the user's input method.
            AutomatedTestHost.becomeBackgroundHost()
            NSApplication.shared.run()
            return
        }
        migrateLegacyPreferencesIfNeeded()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? productionBundleIdentifier
        let duplicate = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).contains { $0.processIdentifier != currentPID }
        if duplicate {
            NSLog("BalanceBar: refusing duplicate instance; pid=%d", currentPID)
            return
        }
        let app = NSApplication.shared
        if InitialLaunchPresentation.resolve(
            silentLaunch: AppPreferences().silentLaunch,
            pendingDashboardRestore: DashboardRestoreStore.peek() != nil
        ) == .background {
            _ = app.setActivationPolicy(.accessory)
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

// Layout rules for the balance error overview card. The error detail must be
// readable in full without truncation. Normal English words stay whole (word
// wrapping); only over-wide unbreakable tokens such as URLs or continuous
// error codes get character-level break opportunities so they cannot overflow.
// The detail occupies the balance card's left column so the amount placeholder
// can remain in the right column without overlap. Kept as a small pure helper
// so the probe can verify wrapping and overlap headlessly.
enum ErrorCardLayout {
    static let cardWidth: CGFloat = 304
    static let horizontalInset: CGFloat = OverviewLayoutMetrics.default.horizontalInset
    static let contentWidth: CGFloat = cardWidth - horizontalInset * 2
    static let detailWidth: CGFloat = amountX - horizontalInset - 7
    static let amountWidth: CGFloat = 141
    static let amountX: CGFloat = cardWidth - horizontalInset - amountWidth
    static let refreshTimeWidth: CGFloat = 81
    static let refreshTimeX: CGFloat = cardWidth - horizontalInset - refreshTimeWidth
    static let subscriptionWidth: CGFloat = 78
    static let subscriptionX = cardWidth - horizontalInset - subscriptionWidth
    // Keep the account marquee's transparent edge a few points before the
    // actual right-aligned subscription glyphs.
    static let subscriptionTextSafetyGap: CGFloat = 8
    // Geometry-only fallback used when the right-aligned subscription text has
    // not been measured yet. Runtime callers refine this to the text edge.
    static let accountWidthWithSubscription = subscriptionX - horizontalInset

    // Match the compact third-party balance card for a single-line error.
    static let minimumCardHeight: CGFloat = 86
    static let singleLineDetailHeight: CGFloat = 17

    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let quotaFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let detailFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 31, weight: .semibold)
    static let refreshTimeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    struct ErrorFrames {
        let cardSize: NSSize
        let title: NSRect
        let refreshTime: NSRect
        let account: NSRect?
        let subscription: NSRect?
        let quotaDetail: NSRect
        let amount: NSRect
        let detail: NSRect
        let detailText: String
    }

    /// Prepares the detail text for word wrapping. Whitespace-delimited tokens
    /// that fit on one line are left untouched, so normal English words stay
    /// whole. Tokens wider than `width` (URLs, continuous error codes, long
    /// unbroken runs) get a zero-width space between every character so they
    /// always have safe break points and can never overflow or be truncated.
    static func detailText(for message: String, width: CGFloat) -> String {
        guard !message.isEmpty else { return message }
        var result = ""
        var token = ""
        for character in message {
            if character.isWhitespace {
                result += wrapIfNeeded(token, width: width)
                result.append(character)
                token = ""
            } else {
                token.append(character)
            }
        }
        result += wrapIfNeeded(token, width: width)
        return result
    }

    private static func wrapIfNeeded(_ token: String, width: CGFloat) -> String {
        guard !token.isEmpty else { return token }
        let tokenWidth = (token as NSString).size(withAttributes: [.font: detailFont]).width
        guard tokenWidth > width else { return token }
        return token.map(String.init).joined(separator: "\u{200B}")
    }

    /// Minimum height that renders the full `message` at `width` using word
    /// wrapping on the break-opportunity text from `detailText(for:width:)`.
    /// Empty and short text keep the compact single-line height.
    static func detailHeight(for message: String, width: CGFloat) -> CGFloat {
        return measuredHeight(of: detailText(for: message, width: width), width: width)
    }

    private static func measuredHeight(of text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return singleLineDetailHeight }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: detailFont, .paragraphStyle: paragraph]
        )
        let measured = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(singleLineDetailHeight, ceil(measured.height) + 1)
    }

    /// Frames for the error card. A single-line detail follows the same three
    /// row rhythm as the compact balance card; additional detail lines shift
    /// the rows above upward by only the extra measured height.
    static func errorFrames(
        for message: String,
        includesAccount: Bool = false,
        includesSubscription: Bool = false,
        subscriptionTextWidth: CGFloat? = nil
    ) -> ErrorFrames {
        let text = detailText(for: message, width: detailWidth)
        let detailH = measuredHeight(of: text, width: detailWidth)
        let extraDetailHeight = max(0, detailH - singleLineDetailHeight)
        let hasSubscription = includesAccount && includesSubscription
        let accountShift: CGFloat = includesAccount ? 19 : 0
        let accountWidth = hasSubscription
            ? accountWidth(forSubscriptionTextWidth: subscriptionTextWidth)
            : contentWidth
        let cardHeight = minimumCardHeight + extraDetailHeight + accountShift
        // The compact one-line amount center is 1pt above the geometric center
        // of the left status/detail region. As that region grows, move the
        // amount by half the extra height to preserve the same optical center.
        let amountY = 5 + extraDetailHeight / 2
        return ErrorFrames(
            cardSize: NSSize(width: cardWidth, height: cardHeight),
            title: NSRect(x: horizontalInset, y: 58 + extraDetailHeight + accountShift, width: 127, height: 20),
            refreshTime: NSRect(x: refreshTimeX, y: 59 + extraDetailHeight + accountShift, width: refreshTimeWidth, height: 17),
            account: includesAccount
                ? NSRect(x: horizontalInset, y: 58 + extraDetailHeight, width: accountWidth, height: 17)
                : nil,
            subscription: hasSubscription
                ? NSRect(
                    x: subscriptionX,
                    y: 58 + extraDetailHeight,
                    width: subscriptionWidth,
                    height: 17
                )
                : nil,
            quotaDetail: NSRect(x: horizontalInset, y: 31 + extraDetailHeight, width: 128, height: 18),
            amount: NSRect(x: amountX, y: amountY, width: amountWidth, height: 48),
            detail: NSRect(x: horizontalInset, y: 7, width: detailWidth, height: detailH),
            detailText: text
        )
    }

    /// The subscription label is right-aligned within its fixed layout frame.
    /// Use its measured text width so the account marquee reaches the visible
    /// subscription text instead of stopping at the frame's unused leading
    /// space, while keeping the same safety gap as the normal card.
    static func accountWidth(forSubscriptionTextWidth textWidth: CGFloat?) -> CGFloat {
        guard let textWidth else { return accountWidthWithSubscription }

        let clampedTextWidth = min(max(0, textWidth), subscriptionWidth)
        let subscriptionTextMinX = subscriptionX + subscriptionWidth - clampedTextWidth
        return max(
            0,
            min(
                contentWidth,
                subscriptionTextMinX
                    - subscriptionTextSafetyGap
                    - horizontalInset
            )
        )
    }

    /// Wrapping label for the error detail. Uses word wrapping on text prepared
    /// by `detailText(for:width:)`, so normal English words stay whole while
    /// over-wide tokens still have safe character-level break points. Never
    /// truncates.
    static func makeRefreshTimeLabel(_ text: String, showsCachedBalance: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = refreshTimeFont
        label.textColor = showsCachedBalance ? .systemRed : .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func makeDetailLabel(
        _ text: String,
        textColor: NSColor = .secondaryLabelColor
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = detailFont
        label.textColor = textColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}
