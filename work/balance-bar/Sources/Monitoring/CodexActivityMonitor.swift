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
    private static let terminalPhases: Set<String> = ["final", "final_answer"]
    private static let startTypes: Set<String> = [
        "task_started", "task_start", "turn_started", "turn_start", "user_message"
    ]
    private static let terminalTypes: Set<String> = [
        "task_complete", "task_completed", "task_stopped", "task_failed", "task_cancelled",
        "turn_complete", "turn_completed", "turn_aborted", "turn_failed", "turn_cancelled"
    ]
    private static let responseTerminalTypes: Set<String> = [
        "response.completed", "response.failed", "response.incomplete", "response.cancelled"
    ]

    private struct SessionCache {
        let size: UInt64
        let modifiedAt: TimeInterval
        let running: Bool
    }

    private struct RolloutCandidate {
        let path: String
        let updatedAt: TimeInterval
    }

    private let codexDirectory: URL
    private let clock: () -> Date
    private var sessionCache: [String: SessionCache] = [:]
    private var rolloutPathsCache: (scannedAt: Date, candidates: [RolloutCandidate]) = (.distantPast, [])

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
        let candidates = recentRolloutPaths(now: now)
        var nextCache: [String: SessionCache] = [:]
        var parsedAny = false
        var anyRunning = false
        for candidate in candidates {
            // The path list is cached for one second, so recheck both clocks
            // on every poll before reusing a cached parse result.
            guard Self.isWithinActivityWindow(candidate.updatedAt, now: now),
                  let identity = codexFileIdentity(atPath: candidate.path),
                  Self.isWithinActivityWindow(identity.modifiedAt, now: now) else { continue }
            parsedAny = true
            let sizeValue = identity.size
            let modifiedValue = identity.modifiedAt
            if let cached = sessionCache[candidate.path],
               cached.size == sizeValue,
               cached.modifiedAt == modifiedValue {
                nextCache[candidate.path] = cached
                anyRunning = anyRunning || cached.running
                continue
            }
            let running = parseSession(path: candidate.path)
            let entry = SessionCache(size: sizeValue, modifiedAt: modifiedValue, running: running)
            nextCache[candidate.path] = entry
            anyRunning = anyRunning || running
        }
        sessionCache = nextCache
        return parsedAny ? anyRunning : nil
    }

    private func recentRolloutPaths(now: Date) -> [RolloutCandidate] {
        if now.timeIntervalSince(rolloutPathsCache.scannedAt) < 1 {
            return rolloutPathsCache.candidates
        }
        guard let databasePath = latestDatabase(prefix: "state_") else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)
        // Codex stores updated_at as Unix seconds and updated_at_ms as Unix
        // milliseconds. Filter before LIMIT so a stale row cannot occupy one
        // of the 24 candidates and poison an otherwise idle startup.
        let updatedAt = "coalesce(nullif(updated_at_ms, 0), updated_at * 1000)"
        let cutoff = Int64((now.timeIntervalSince1970 - TimeInterval(Self.activityWindow)) * 1000)
        let sql = """
        SELECT rollout_path, \(updatedAt)
        FROM threads
        WHERE rollout_path <> ''
          AND \(updatedAt) >= ?
        ORDER BY \(updatedAt) DESC
        LIMIT 24
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)
        var candidates: [RolloutCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let updatedAtMilliseconds = sqlite3_column_int64(statement, 1)
            candidates.append(RolloutCandidate(
                path: String(cString: text),
                updatedAt: TimeInterval(updatedAtMilliseconds) / 1000
            ))
        }
        rolloutPathsCache = (now, candidates)
        return candidates
    }

    private static func isWithinActivityWindow(_ timestamp: TimeInterval, now: Date) -> Bool {
        let age = now.timeIntervalSince1970 - timestamp
        return age >= 0 && age < TimeInterval(activityWindow)
    }

    private func parseSession(path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let size = try? handle.seekToEnd() else { return false }
        let offset = size > 256 * 1024 ? size - 256 * 1024 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return false }
        let text = String(decoding: data, as: UTF8.self)
        var running = false
        var terminalSeen = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let topType = object["type"] as? String else { continue }
            if Self.responseTerminalTypes.contains(topType) {
                running = false
                terminalSeen = true
                continue
            }
            if topType == "event_msg", let payload = object["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String {
                if payloadType == "agent_message",
                   let phase = payload["phase"] as? String,
                   Self.terminalPhases.contains(phase) {
                    running = false
                    terminalSeen = true
                } else if Self.terminalTypes.contains(payloadType)
                            || Self.responseTerminalTypes.contains(payloadType) {
                    running = false
                    terminalSeen = true
                } else if Self.startTypes.contains(payloadType) {
                    running = true
                    terminalSeen = false
                } else if payloadType == "agent_message", !terminalSeen {
                    running = true
                }
            } else if topType == "response_item", let payload = object["payload"] as? [String: Any] {
                let phase = payload["phase"] as? String
                if let phase, Self.terminalPhases.contains(phase) {
                    running = false
                    terminalSeen = true
                } else if payload["status"] as? String == "in_progress", !terminalSeen {
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

        // Require an explicit response-in-progress event to start activity;
        // streaming output then keeps that active turn alive until a terminal
        // event wins. Output from an older completed turn is not sufficient.
        let normalized = "replace(feedback_log_body, ' ', '')"
        let outputActivity = """
        \(normalized) like '%response.output_item.added%'
        or \(normalized) like '%response.output_text.delta%'
        """
        let inProgress = """
        \(normalized) like '%response.in_progress%'
        or \(normalized) like '%\"status\":\"in_progress\"%'
        """
        let activity = "\(outputActivity) or \(inProgress)"
        let completion = ([
            "\(normalized) like '%\"phase\":\"final\"%'",
            "\(normalized) like '%\"phase\":\"final_answer\"%'"
        ] + (Self.terminalTypes.union(Self.responseTerminalTypes)).sorted().map {
            "\(normalized) like '%\"type\":\"\($0)\"%'"
        })
            .joined(separator: " or ")
        let sql = """
        select
          max(case when \(activity) then ts else 0 end) as latest_activity,
          max(case when \(inProgress) then ts else 0 end) as latest_in_progress,
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
            let latestInProgress = sqlite3_column_int64(statement, 1)
            let latestDone = sqlite3_column_int64(statement, 2)
            if latestInProgress > latestDone,
               latestActivity > latestDone,
               nowEpoch - latestActivity < Int64(Self.activityWindow) {
                return true
            }
            // Events can share a one-second timestamp. Keep a short grace
            // period so an active stream does not flicker off at that boundary.
            // A known completion wins when both events have the same timestamp,
            // and output alone is not a positive in-progress signal.
            if latestInProgress > latestDone,
               latestActivity > 0,
               latestDone == 0,
               nowEpoch - latestActivity < 20 {
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
