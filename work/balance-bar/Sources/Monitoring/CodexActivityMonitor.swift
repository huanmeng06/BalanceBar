import Foundation
import SQLite3
import Darwin

private func codexFileIdentity(atPath path: String) -> (size: UInt64, modifiedAt: TimeInterval)? {
    var value = stat()
    guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
    let modifiedAt = TimeInterval(value.st_mtimespec.tv_sec)
        + (TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000)
    return (UInt64(max(0, value.st_size)), modifiedAt)
}

final class CodexActivityMonitor {
    private static let activityWindow = 10 * 60
    private static let terminalTypes: Set<String> = [
        "task_complete", "task_completed", "task_stopped", "task_failed", "task_cancelled",
        "turn_complete", "turn_completed", "turn_aborted", "turn_failed", "turn_cancelled"
    ]

    private struct SessionCache {
        let size: UInt64
        let modifiedAt: TimeInterval
        let running: Bool
    }

    private let codexDirectory: URL
    private let clock: () -> Date
    private var sessionCache: [String: SessionCache] = [:]
    private var rolloutPathsCache: (scannedAt: Date, paths: [String]) = (.distantPast, [])

    init(codexDirectory: URL? = nil, clock: @escaping () -> Date = { Date() }) {
        self.codexDirectory = codexDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.clock = clock
    }

    func isTaskRunning(now: Date? = nil) -> Bool {
        let now = now ?? clock()
        // A rollout task_complete/failure/cancellation event is authoritative.
        // Only use the delayed logs database when rollout files are unavailable.
        if let rolloutState = recentRolloutRunningState(now: now) { return rolloutState }
        return logsDatabaseIsRunning(now: now)
    }

    private func recentRolloutRunningState(now: Date) -> Bool? {
        let paths = recentRolloutPaths()
        var nextCache: [String: SessionCache] = [:]
        var parsedAny = false
        var anyRunning = false
        for path in paths {
            guard let identity = codexFileIdentity(atPath: path) else { continue }
            parsedAny = true
            let sizeValue = identity.size
            let modifiedValue = identity.modifiedAt
            if let cached = sessionCache[path],
               cached.size == sizeValue,
               cached.modifiedAt == modifiedValue {
                nextCache[path] = cached
                anyRunning = anyRunning || cached.running
                continue
            }
            let running = parseSession(path: path)
            let entry = SessionCache(size: sizeValue, modifiedAt: modifiedValue, running: running)
            nextCache[path] = entry
            anyRunning = anyRunning || running
        }
        sessionCache = nextCache
        return parsedAny ? anyRunning : nil
    }

    private func recentRolloutPaths() -> [String] {
        let now = clock()
        if now.timeIntervalSince(rolloutPathsCache.scannedAt) < 1 {
            return rolloutPathsCache.paths
        }
        guard let databasePath = latestDatabase(prefix: "state_") else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)
        let sql = "SELECT rollout_path FROM threads WHERE rollout_path <> '' ORDER BY updated_at DESC, updated_at_ms DESC LIMIT 24"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            paths.append(String(cString: text))
        }
        rolloutPathsCache = (now, paths)
        return paths
    }

    private func parseSession(path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let size = try? handle.seekToEnd() else { return false }
        let offset = size > 256 * 1024 ? size - 256 * 1024 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return false }
        let text = String(decoding: data, as: UTF8.self)
        var running = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let topType = object["type"] as? String else { continue }
            if topType == "event_msg", let payload = object["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String {
                if payloadType == "task_started" || payloadType == "user_message" || payloadType == "agent_message" {
                    running = true
                } else if Self.terminalTypes.contains(payloadType) {
                    running = false
                }
            } else if topType == "response_item", let payload = object["payload"] as? [String: Any] {
                let phase = payload["phase"] as? String
                if phase == "final" || phase == "final_answer" {
                    running = false
                } else {
                    running = true
                }
            }
        }
        return running
    }

    private func logsDatabaseIsRunning(now: Date) -> Bool {
        guard let databasePath = latestDatabase(prefix: "logs_") else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return false }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)

        // This follows codex-monitor's activity model: streaming/in-progress
        // events start activity, while task/turn terminal events stop it.
        let normalized = "replace(feedback_log_body, ' ', '')"
        let activity = """
        \(normalized) like '%response.output_item.added%'
        or \(normalized) like '%response.output_text.delta%'
        or \(normalized) like '%\"status\":\"in_progress\"%'
        """
        let completion = ([
            "\(normalized) like '%\"phase\":\"final\"%'",
            "\(normalized) like '%\"phase\":\"final_answer\"%'"
        ] + Self.terminalTypes.sorted().map { "\(normalized) like '%\"type\":\"\($0)\"%'" })
            .joined(separator: " or ")
        let sql = """
        select
          max(case when \(activity) then ts else 0 end) as latest_activity,
          max(case when \(completion) then ts else 0 end) as latest_done
        from logs indexed by idx_logs_ts
        where thread_id is not null
          and ts >= ?
          and (\(activity) or \(completion))
        group by thread_id
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let nowEpoch = Int64(now.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 1, nowEpoch - Int64(Self.activityWindow))

        while sqlite3_step(statement) == SQLITE_ROW {
            let latestActivity = sqlite3_column_int64(statement, 0)
            let latestDone = sqlite3_column_int64(statement, 1)
            if latestActivity > latestDone, nowEpoch - latestActivity < Int64(Self.activityWindow) {
                return true
            }
            // Events can share a one-second timestamp. Keep a short grace
            // period so an active stream does not flicker off at that boundary.
            if latestActivity > 0, latestActivity >= latestDone, nowEpoch - latestActivity < 20 {
                return true
            }
        }
        return false
    }

    private func latestDatabase(prefix: String) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: codexDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        return files.compactMap { url -> (version: Int, path: String)? in
            guard url.pathExtension == "sqlite" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix), let version = Int(name.dropFirst(prefix.count)) else { return nil }
            return (version, url.path)
        }.max { $0.version < $1.version }?.path
    }
}
