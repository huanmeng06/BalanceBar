import Foundation
import SQLite3
import Darwin

private struct CodexFileIdentity: Equatable {
    let size: UInt64
    let modifiedAt: TimeInterval
    let fileID: UInt64
}

private func codexFileIdentity(atPath path: String) -> CodexFileIdentity? {
    var value = stat()
    guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
    let modifiedAt = TimeInterval(value.st_mtimespec.tv_sec)
        + (TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000)
    return CodexFileIdentity(
        size: UInt64(max(0, value.st_size)),
        modifiedAt: modifiedAt,
        fileID: UInt64(value.st_ino)
    )
}

final class CodexActivityMonitor {
    private static let activityWindow = 10 * 60
    private static let activityTailBytes = 256 * 1024
    private static let lifecycleLookbackBytes = 4 * 1024 * 1024
    private static let terminalPhases: Set<String> = ["final", "final_answer"]
    private static let startTypes: Set<String> = [
        "task_started", "task_start", "turn_started", "turn_start", "user_message"
    ]
    private static let terminalTypes: Set<String> = [
        "task_complete", "task_completed", "task_stopped", "task_failed", "task_cancelled",
        "turn_complete", "turn_completed", "turn_aborted", "turn_failed", "turn_cancelled"
    ]
    private static let contextCompactionTypes: Set<String> = [
        "compacted", "context_compacted"
    ]
    private static let ongoingActivityTypes: Set<String> = [
        "agent_reasoning", "reasoning", "function_call", "function_call_output",
        "custom_tool_call", "custom_tool_call_output",
        "tool_search_call", "tool_search_output"
    ]
    private static let terminalResponseItemTypes: Set<String> = ["message"]
    private static let responseTerminalTypes: Set<String> = [
        "response.completed", "response.failed", "response.incomplete", "response.cancelled"
    ]
    private static let responseTerminalStatuses: Set<String> = [
        "completed", "failed", "cancelled", "canceled", "incomplete"
    ]

    private struct SessionCache {
        let identity: CodexFileIdentity
        let bytesScanned: UInt64
        let pendingLine: String
        let running: Bool
        let terminalSeen: Bool
    }

    private struct DatabaseSignature: Equatable {
        let path: String
        let main: CodexFileIdentity
        let wal: CodexFileIdentity?
        let sharedMemory: CodexFileIdentity?
    }

    private struct LogsActivityCache {
        let signature: DatabaseSignature
        let running: Bool
        let validUntil: TimeInterval
    }

    private struct RolloutCandidate {
        let path: String
        let updatedAt: TimeInterval
    }

    private let codexDirectory: URL
    private let clock: () -> Date
    private var sessionCache: [String: SessionCache] = [:]
    private var rolloutPathsCache: (scannedAt: Date, candidates: [RolloutCandidate]) = (.distantPast, [])
    private var latestDatabaseCache: [String: (scannedAt: Date, path: String)] = [:]
    private var logsActivityCache: LogsActivityCache?

    init(codexDirectory: URL? = nil, clock: @escaping () -> Date = { Date() }) {
        self.codexDirectory = codexDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.clock = clock
    }

    func isTaskRunning(now: Date? = nil) -> Bool {
        let now = now ?? clock()
        // Read the indexed activity log first because it is the cheapest
        // aggregate signal. A rollout result, when available, remains
        // authoritative so a delayed log completion cannot resurrect a task
        // that the session file has already ended.
        let logsState = logsDatabaseIsRunning(now: now)

        // Keep rollout parsing as a compatibility path for older/incomplete
        // logs databases. Its state is incremental, so an active append only
        // parses the bytes that arrived since the previous sample.
        return recentRolloutRunningState(now: now) ?? logsState ?? false
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
            if let cached = sessionCache[candidate.path],
               cached.identity == identity {
                nextCache[candidate.path] = cached
                anyRunning = anyRunning || cached.running
                continue
            }
            guard let entry = parseSession(
                path: candidate.path,
                identity: identity,
                cached: sessionCache[candidate.path]
            ) else { continue }
            nextCache[candidate.path] = entry
            anyRunning = anyRunning || entry.running
        }
        sessionCache = nextCache
        return parsedAny ? anyRunning : nil
    }

    private func recentRolloutPaths(now: Date) -> [RolloutCandidate] {
        if now.timeIntervalSince(rolloutPathsCache.scannedAt) < 1 {
            return rolloutPathsCache.candidates
        }
        guard let databasePath = latestDatabase(prefix: "state_", now: now) else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)
        // Codex stores updated_at as Unix seconds and updated_at_ms as Unix
        // milliseconds. Filter before reading rollout files so stale rows
        // cannot poison an otherwise idle startup. Do not cap the result set:
        // activity is aggregated across tasks, and an older running task must
        // remain visible after a newer task is stopped.
        let updatedAt = "coalesce(nullif(updated_at_ms, 0), updated_at * 1000)"
        let cutoff = Int64((now.timeIntervalSince1970 - TimeInterval(Self.activityWindow)) * 1000)
        let sql = """
        SELECT rollout_path, \(updatedAt)
        FROM threads
        WHERE rollout_path <> ''
          AND \(updatedAt) >= ?
        ORDER BY \(updatedAt) DESC
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

    private func parseSession(
        path: String,
        identity: CodexFileIdentity,
        cached: SessionCache?
    ) -> SessionCache? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        let canContinue = cached.map {
            $0.identity.fileID == identity.fileID
                // A same-size mtime change can be an in-place rewrite. Reset
                // in that case instead of seeking past the rewritten bytes.
                && identity.size > $0.identity.size
                && identity.modifiedAt >= $0.identity.modifiedAt
                && $0.bytesScanned <= identity.size
        } ?? false
        let startOffset: UInt64
        var running: Bool
        var terminalSeen: Bool
        var pendingLine: String
        if canContinue, let cached {
            // Codex appends to a session file. Continue from the previous byte
            // offset and retain an unterminated final line across polls.
            startOffset = cached.bytesScanned
            running = cached.running
            terminalSeen = cached.terminalSeen
            pendingLine = cached.pendingLine
        } else {
            let tailOffset = identity.size > UInt64(Self.activityTailBytes)
                ? identity.size - UInt64(Self.activityTailBytes)
                : 0
            startOffset = tailOffset > UInt64(Self.lifecycleLookbackBytes)
                ? tailOffset - UInt64(Self.lifecycleLookbackBytes)
                : 0
            running = false
            terminalSeen = false
            pendingLine = ""
        }

        guard startOffset <= identity.size,
              identity.size - startOffset <= UInt64(Int.max) else {
            return nil
        }
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return nil
        }
        guard let data = try? handle.read(upToCount: Int(identity.size - startOffset)) else {
            return nil
        }

        let pendingByteCount = pendingLine.utf8.count
        let combinedStartOffset = startOffset >= UInt64(pendingByteCount)
            ? startOffset - UInt64(pendingByteCount)
            : 0
        let tailOffset = identity.size > UInt64(Self.activityTailBytes)
            ? identity.size - UInt64(Self.activityTailBytes)
            : 0
        var combined = Data(pendingLine.utf8)
        combined.append(data)
        let bytes = Array(combined)
        var lineStart = 0
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\n") else {
                index += 1
                continue
            }
            let lineData = Data(bytes[lineStart..<index])
            let absoluteLineStart = combinedStartOffset + UInt64(lineStart)
            consumeSessionLine(
                lineData,
                lifecycleOnly: absoluteLineStart < tailOffset,
                running: &running,
                terminalSeen: &terminalSeen
            )
            lineStart = index + 1
            index += 1
        }

        pendingLine = String(decoding: bytes[lineStart..<bytes.count], as: UTF8.self)
        return SessionCache(
            identity: identity,
            bytesScanned: identity.size,
            pendingLine: pendingLine,
            running: running,
            terminalSeen: terminalSeen
        )
    }

    private func consumeSessionLine(
        _ lineData: Data,
        lifecycleOnly: Bool,
        running: inout Bool,
        terminalSeen: inout Bool
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let topType = object["type"] as? String else { return }
        if Self.contextCompactionTypes.contains(topType) {
            // Context compaction continues the same task after a prior
            // final_answer marker. It is a lifecycle boundary, not activity
            // itself; wait for explicit reasoning or tool activity to reopen.
            running = false
            terminalSeen = false
            return
        }
        if Self.responseTerminalTypes.contains(topType) {
            running = false
            terminalSeen = true
            return
        }
        if topType == "event_msg", let payload = object["payload"] as? [String: Any],
           let payloadType = payload["type"] as? String {
            if Self.contextCompactionTypes.contains(payloadType) {
                running = false
                terminalSeen = false
            } else if payloadType == "agent_message",
               let phase = payload["phase"] as? String,
               Self.terminalPhases.contains(phase) {
                running = false
                terminalSeen = true
            } else if Self.terminalTypes.contains(payloadType)
                        || Self.responseTerminalTypes.contains(payloadType) {
                running = false
                terminalSeen = true
            } else if Self.startTypes.contains(payloadType) {
                // A start before the activity tail only reopens the lifecycle
                // context. It must not make arbitrary recent output active.
                running = lifecycleOnly ? false : true
                terminalSeen = false
            } else if !lifecycleOnly,
                      Self.ongoingActivityTypes.contains(payloadType),
                      !terminalSeen {
                running = true
            }
        } else if topType == "response_item", let payload = object["payload"] as? [String: Any] {
            let phase = payload["phase"] as? String
            let status = payload["status"] as? String
            let payloadType = payload["type"] as? String
            if let payloadType, Self.contextCompactionTypes.contains(payloadType) {
                running = false
                terminalSeen = false
            } else if let phase, Self.terminalPhases.contains(phase) {
                running = false
                terminalSeen = true
            } else if let status,
                      Self.responseTerminalStatuses.contains(status),
                      payloadType == nil || Self.terminalResponseItemTypes.contains(payloadType ?? "") {
                running = false
                terminalSeen = true
            } else if !lifecycleOnly, status == "in_progress", !terminalSeen {
                running = true
            } else if !lifecycleOnly,
                      let payloadType,
                      Self.ongoingActivityTypes.contains(payloadType),
                      !terminalSeen {
                running = true
            }
        } else if !lifecycleOnly,
                  Self.ongoingActivityTypes.contains(topType),
                  !terminalSeen {
            running = true
        }
    }

    private func logsDatabaseIsRunning(now: Date) -> Bool? {
        guard let databasePath = latestDatabase(prefix: "logs_", now: now),
              let signature = databaseSignature(atPath: databasePath) else {
            return nil
        }

        let nowEpoch = Int64(now.timeIntervalSince1970)
        if let cached = logsActivityCache,
           cached.signature == signature,
           !cached.running || now.timeIntervalSince1970 < cached.validUntil {
            return cached.running
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return nil
        }
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
        let completion = (Self.terminalTypes.union(Self.responseTerminalTypes)).sorted().map {
            "\(normalized) like '%\"type\":\"\($0)\"%'"
        }
        .joined(separator: " or ")
        let phaseCompletion = """
        \(normalized) like '%\"phase\":\"final\"%'
        or \(normalized) like '%\"phase\":\"final_answer\"%'
        """
        let sql = """
        SELECT
          max(CASE WHEN \(activity) THEN ts ELSE 0 END) AS latest_activity,
          max(CASE WHEN \(inProgress) THEN ts ELSE 0 END) AS latest_in_progress,
          max(CASE WHEN (\(completion)) OR (\(phaseCompletion)) THEN ts ELSE 0 END) AS latest_done
        FROM logs INDEXED BY idx_logs_ts
        WHERE thread_id IS NOT NULL
          AND ts >= ?
          AND ((\(activity)) OR (\(completion)) OR (\(phaseCompletion)))
        GROUP BY thread_id;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, nowEpoch - Int64(Self.activityWindow))

        var runningUntil: TimeInterval?
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            let latestActivity = sqlite3_column_int64(statement, 0)
            let latestInProgress = sqlite3_column_int64(statement, 1)
            let latestDone = sqlite3_column_int64(statement, 2)
            if latestInProgress > latestDone,
               latestActivity > latestDone,
               nowEpoch - latestActivity < Int64(Self.activityWindow) {
                let expiresAt = TimeInterval(latestActivity + Int64(Self.activityWindow))
                runningUntil = max(runningUntil ?? .leastNormalMagnitude, expiresAt)
            } else if latestInProgress > latestDone,
                      latestActivity > 0,
                      latestDone == 0,
                      nowEpoch - latestActivity < 20 {
                // Events can share a one-second timestamp. Keep a short grace
                // period so an active stream does not flicker off at a boundary.
                let expiresAt = TimeInterval(latestActivity + 20)
                runningUntil = max(runningUntil ?? .leastNormalMagnitude, expiresAt)
            }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else { return nil }

        let running = runningUntil != nil
        logsActivityCache = LogsActivityCache(
            signature: signature,
            running: running,
            validUntil: runningUntil ?? .infinity
        )
        return running
    }

    private func databaseSignature(atPath path: String) -> DatabaseSignature? {
        guard let main = codexFileIdentity(atPath: path) else { return nil }
        return DatabaseSignature(
            path: path,
            main: main,
            wal: codexFileIdentity(atPath: "\(path)-wal"),
            sharedMemory: codexFileIdentity(atPath: "\(path)-shm")
        )
    }

    private func latestDatabase(prefix: String, now: Date) -> String? {
        if let cached = latestDatabaseCache[prefix],
           now.timeIntervalSince(cached.scannedAt) < 1 {
            return cached.path
        }
        guard let path = (try? FileManager.default.contentsOfDirectory(
            at: codexDirectory,
            includingPropertiesForKeys: nil
        ))?.compactMap({ url -> (version: Int, path: String)? in
            guard url.pathExtension == "sqlite" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix), let version = Int(name.dropFirst(prefix.count)) else { return nil }
            return (version, url.path)
        }).max(by: { $0.version < $1.version })?.path else {
            return nil
        }
        latestDatabaseCache[prefix] = (now, path)
        return path
    }
}
