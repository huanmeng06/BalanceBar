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
    private static let completionTypes: Set<String> = terminalTypes.union(responseTerminalTypes)
    private static let responseTerminalStatuses: Set<String> = [
        "completed", "failed", "cancelled", "canceled", "incomplete"
    ]

    private struct SessionCache {
        let identity: CodexFileIdentity
        let bytesScanned: UInt64
        let pendingLine: String
        let running: Bool
        let terminalSeen: Bool
        let hardTerminalSeen: Bool
        let contextCompactionSeen: Bool
    }

    private struct DatabaseSignature: Equatable {
        let path: String
        let main: CodexFileIdentity
        let wal: CodexFileIdentity?
        let sharedMemory: CodexFileIdentity?
    }

    private struct ThreadLogState {
        var latestActivity: Int64 = 0
        var latestInProgress: Int64 = 0
        var latestDone: Int64 = 0
        var latestHardTerminal: Int64 = 0
        var latestContextCompaction: Int64 = 0
    }

    private struct LogsScanCache {
        let databasePath: String
        let databaseFileID: UInt64
        var observedSignature: DatabaseSignature
        var lastRowID: Int64
        var threads: [String: ThreadLogState]
    }

    private struct LogsActivityEvaluation {
        let isRunning: Bool
        let hasHardTerminal: Bool
        let hasContextCompaction: Bool
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
    private var logsScanCache: LogsScanCache?

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
        return activityObservation(now: now).legacyIsTaskRunning
    }

    /// Returns lifecycle evidence for ActivityCoordinator while keeping the
    /// legacy Boolean method's meaning stable for existing callers/tests.
    func activityObservation(now: Date? = nil) -> ActivityMonitorObservation {
        let now = now ?? clock()
        if let rolloutObservation = recentRolloutActivityObservation(now: now) {
            return rolloutObservation
        }
        return logsDatabaseActivityObservation(now: now) ?? .ambiguousIdle
    }

    private func recentRolloutActivityObservation(now: Date) -> ActivityMonitorObservation? {
        let candidates = recentRolloutPaths(now: now)
        var nextCache: [String: SessionCache] = [:]
        var parsedAny = false
        var anyRunning = false
        var anyContextCompaction = false
        var anyHardTerminal = false
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
                anyContextCompaction = anyContextCompaction || cached.contextCompactionSeen
                anyHardTerminal = anyHardTerminal || cached.hardTerminalSeen
                continue
            }
            guard let entry = parseSession(
                path: candidate.path,
                identity: identity,
                cached: sessionCache[candidate.path]
            ) else { continue }
            nextCache[candidate.path] = entry
            anyRunning = anyRunning || entry.running
            anyContextCompaction = anyContextCompaction || entry.contextCompactionSeen
            anyHardTerminal = anyHardTerminal || entry.hardTerminalSeen
        }
        sessionCache = nextCache
        guard parsedAny else { return nil }
        if anyRunning { return .active }
        if anyContextCompaction { return .contextCompaction }
        if anyHardTerminal { return .hardTerminal }
        return .ambiguousIdle
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
        var hardTerminalSeen: Bool
        var contextCompactionSeen: Bool
        var pendingLine: String
        if canContinue, let cached {
            // Codex appends to a session file. Continue from the previous byte
            // offset and retain an unterminated final line across polls.
            startOffset = cached.bytesScanned
            running = cached.running
            terminalSeen = cached.terminalSeen
            hardTerminalSeen = cached.hardTerminalSeen
            contextCompactionSeen = cached.contextCompactionSeen
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
            hardTerminalSeen = false
            contextCompactionSeen = false
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
        if pendingLine.isEmpty {
            pendingLine = consumeSessionData(
                data,
                combinedStartOffset: combinedStartOffset,
                tailOffset: tailOffset,
                running: &running,
                terminalSeen: &terminalSeen,
                hardTerminalSeen: &hardTerminalSeen,
                contextCompactionSeen: &contextCompactionSeen
            )
        } else {
            var combined = Data(pendingLine.utf8)
            combined.append(data)
            pendingLine = consumeSessionData(
                combined,
                combinedStartOffset: combinedStartOffset,
                tailOffset: tailOffset,
                running: &running,
                terminalSeen: &terminalSeen,
                hardTerminalSeen: &hardTerminalSeen,
                contextCompactionSeen: &contextCompactionSeen
            )
        }
        return SessionCache(
            identity: identity,
            bytesScanned: identity.size,
            pendingLine: pendingLine,
            running: running,
            terminalSeen: terminalSeen,
            hardTerminalSeen: hardTerminalSeen,
            contextCompactionSeen: contextCompactionSeen
        )
    }

    private func consumeSessionData(
        _ data: Data,
        combinedStartOffset: UInt64,
        tailOffset: UInt64,
        running: inout Bool,
        terminalSeen: inout Bool,
        hardTerminalSeen: inout Bool,
        contextCompactionSeen: inout Bool
    ) -> String {
        var lineStart = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == UInt8(ascii: "\n") {
                let lineData = data.subdata(in: lineStart..<index)
                let lineOffset = combinedStartOffset
                    + UInt64(data.distance(from: data.startIndex, to: lineStart))
                consumeSessionLine(
                    lineData,
                    lifecycleOnly: lineOffset < tailOffset,
                    running: &running,
                    terminalSeen: &terminalSeen,
                    hardTerminalSeen: &hardTerminalSeen,
                    contextCompactionSeen: &contextCompactionSeen
                )
                lineStart = data.index(after: index)
                index = lineStart
            } else {
                index = data.index(after: index)
            }
        }
        return String(decoding: data[lineStart..<data.endIndex], as: UTF8.self)
    }

    private func consumeSessionLine(
        _ lineData: Data,
        lifecycleOnly: Bool,
        running: inout Bool,
        terminalSeen: inout Bool,
        hardTerminalSeen: inout Bool,
        contextCompactionSeen: inout Bool
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let topType = object["type"] as? String else { return }
        if Self.contextCompactionTypes.contains(topType) {
            // Context compaction continues the same task after a prior
            // final_answer marker. Keep it as separate lifecycle evidence so
            // the coordinator can keep the task active without a compaction
            // timer, while the legacy Boolean remains unchanged.
            running = false
            terminalSeen = false
            hardTerminalSeen = false
            contextCompactionSeen = true
            return
        }
        if Self.responseTerminalTypes.contains(topType) {
            running = false
            terminalSeen = true
            hardTerminalSeen = true
            contextCompactionSeen = false
            return
        }
        if topType == "event_msg", let payload = object["payload"] as? [String: Any],
           let payloadType = payload["type"] as? String {
            if Self.contextCompactionTypes.contains(payloadType) {
                running = false
                terminalSeen = false
                hardTerminalSeen = false
                contextCompactionSeen = true
            } else if payloadType == "agent_message",
               let phase = payload["phase"] as? String,
               Self.terminalPhases.contains(phase) {
                running = false
                terminalSeen = true
                contextCompactionSeen = false
            } else if Self.terminalTypes.contains(payloadType)
                        || Self.responseTerminalTypes.contains(payloadType) {
                running = false
                terminalSeen = true
                hardTerminalSeen = true
                contextCompactionSeen = false
            } else if Self.startTypes.contains(payloadType) {
                // A start before the activity tail only reopens the lifecycle
                // context. It must not make arbitrary recent output active.
                running = lifecycleOnly ? false : true
                terminalSeen = false
                hardTerminalSeen = false
                contextCompactionSeen = false
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
                hardTerminalSeen = false
                contextCompactionSeen = true
            } else if let phase, Self.terminalPhases.contains(phase) {
                running = false
                terminalSeen = true
                contextCompactionSeen = false
            } else if let status,
                      Self.responseTerminalStatuses.contains(status),
                      payloadType == nil || Self.terminalResponseItemTypes.contains(payloadType ?? "") {
                running = false
                terminalSeen = true
                hardTerminalSeen = true
                contextCompactionSeen = false
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

    private func logsDatabaseActivityObservation(now: Date) -> ActivityMonitorObservation? {
        guard let databasePath = latestDatabase(prefix: "logs_", now: now),
              let signature = databaseSignature(atPath: databasePath) else {
            return nil
        }

        if let cached = logsScanCache,
           cached.observedSignature == signature {
            var nextCache = cached
            let evaluation = pruneAndEvaluateLogs(now: now, cache: &nextCache)
            logsScanCache = nextCache
            return observation(for: evaluation)
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)

        guard let highWaterMark = maximumLogRowID(in: database) else {
            return nil
        }

        let shouldBootstrap: Bool
        if let cached = logsScanCache {
            shouldBootstrap = cached.databasePath != databasePath
                || cached.databaseFileID != signature.main.fileID
                || highWaterMark < cached.lastRowID
        } else {
            shouldBootstrap = true
        }

        var nextCache = shouldBootstrap
            ? LogsScanCache(
                databasePath: databasePath,
                databaseFileID: signature.main.fileID,
                observedSignature: signature,
                lastRowID: 0,
                threads: [:]
            )
            : logsScanCache!
        if shouldBootstrap || highWaterMark > nextCache.lastRowID {
            var candidateThreads = nextCache.threads
            guard scanLogs(
                in: database,
                bootstrap: shouldBootstrap,
                afterRowID: nextCache.lastRowID,
                throughRowID: highWaterMark,
                cutoff: Int64(now.timeIntervalSince1970) - Int64(Self.activityWindow),
                threads: &candidateThreads
            ) else {
                return nil
            }
            nextCache.threads = candidateThreads
            nextCache.lastRowID = highWaterMark
        }

        nextCache.observedSignature = signature
        let evaluation = pruneAndEvaluateLogs(now: now, cache: &nextCache)
        logsScanCache = nextCache
        return observation(for: evaluation)
    }

    private func observation(for evaluation: LogsActivityEvaluation) -> ActivityMonitorObservation {
        if evaluation.isRunning { return .active }
        if evaluation.hasContextCompaction { return .contextCompaction }
        if evaluation.hasHardTerminal { return .hardTerminal }
        return .ambiguousIdle
    }

    private func pruneAndEvaluateLogs(
        now: Date,
        cache: inout LogsScanCache
    ) -> LogsActivityEvaluation {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        let cutoff = nowEpoch - Int64(Self.activityWindow)
        cache.threads = cache.threads.filter { _, state in
            max(
                max(state.latestActivity, state.latestInProgress),
                max(state.latestDone, max(state.latestHardTerminal, state.latestContextCompaction))
            ) >= cutoff
        }

        var runningUntil: TimeInterval?
        var hasHardTerminal = false
        var hasContextCompaction = false
        for state in cache.threads.values {
            if state.latestInProgress > state.latestDone,
               state.latestActivity > state.latestDone,
               nowEpoch - state.latestActivity < Int64(Self.activityWindow) {
                let expiresAt = TimeInterval(state.latestActivity + Int64(Self.activityWindow))
                runningUntil = max(runningUntil ?? .leastNormalMagnitude, expiresAt)
            } else if state.latestInProgress > state.latestDone,
                      state.latestActivity > 0,
                      state.latestDone == 0,
                      nowEpoch - state.latestActivity < 20 {
                // Events can share a one-second timestamp. Keep a short grace
                // period so an active stream does not flicker off at a boundary.
                let expiresAt = TimeInterval(state.latestActivity + 20)
                runningUntil = max(runningUntil ?? .leastNormalMagnitude, expiresAt)
            }

            if state.latestContextCompaction > state.latestDone {
                hasContextCompaction = true
            } else if state.latestHardTerminal >= state.latestDone,
                      state.latestHardTerminal > 0 {
                hasHardTerminal = true
            }
        }
        return LogsActivityEvaluation(
            isRunning: runningUntil != nil,
            hasHardTerminal: hasHardTerminal,
            hasContextCompaction: hasContextCompaction
        )
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

    private func maximumLogRowID(in database: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        let sql = "SELECT max(rowid) FROM logs;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func scanLogs(
        in database: OpaquePointer,
        bootstrap: Bool,
        afterRowID: Int64,
        throughRowID: Int64,
        cutoff: Int64,
        threads: inout [String: ThreadLogState]
    ) -> Bool {
        let sql: String
        if bootstrap {
            sql = """
            SELECT rowid, thread_id, ts, feedback_log_body
            FROM logs INDEXED BY idx_logs_ts
            WHERE thread_id IS NOT NULL
              AND ts >= ?
              AND rowid <= ?
            ORDER BY ts, rowid;
            """
        } else {
            sql = """
            SELECT rowid, thread_id, ts, feedback_log_body
            FROM logs
            WHERE rowid > ?
              AND rowid <= ?
              AND thread_id IS NOT NULL
            ORDER BY rowid;
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        if bootstrap {
            sqlite3_bind_int64(statement, 1, cutoff)
            sqlite3_bind_int64(statement, 2, throughRowID)
        } else {
            sqlite3_bind_int64(statement, 1, afterRowID)
            sqlite3_bind_int64(statement, 2, throughRowID)
        }

        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let threadText = sqlite3_column_text(statement, 1) else {
                stepResult = sqlite3_step(statement)
                continue
            }
            let threadID = String(cString: threadText)
            let timestamp = sqlite3_column_int64(statement, 2)
            let body = sqlite3_column_text(statement, 3).map(String.init(cString:)) ?? ""
            let signals = classifyLogBody(body)
            if signals.activity || signals.inProgress || signals.done || signals.contextCompaction {
                var state = threads[threadID] ?? ThreadLogState()
                if signals.activity {
                    state.latestActivity = max(state.latestActivity, timestamp)
                }
                if signals.inProgress {
                    state.latestInProgress = max(state.latestInProgress, timestamp)
                }
                if signals.done {
                    state.latestDone = max(state.latestDone, timestamp)
                }
                if signals.hardTerminal {
                    state.latestHardTerminal = max(state.latestHardTerminal, timestamp)
                }
                if signals.contextCompaction {
                    state.latestContextCompaction = max(state.latestContextCompaction, timestamp)
                }
                threads[threadID] = state
            }
            stepResult = sqlite3_step(statement)
        }
        return stepResult == SQLITE_DONE
    }

    private func classifyLogBody(_ body: String) -> (
        activity: Bool,
        inProgress: Bool,
        done: Bool,
        hardTerminal: Bool,
        contextCompaction: Bool
    ) {
        // Keep the existing SQL semantics: remove literal spaces once, then
        // classify the normalized body without asking SQLite to rescan it.
        let normalized = body.replacingOccurrences(of: " ", with: "").lowercased()
        let outputActivity = normalized.contains("response.output_item.added")
            || normalized.contains("response.output_text.delta")
        let inProgress = normalized.contains("response.in_progress")
            || normalized.contains("\"status\":\"in_progress\"")
        let hardTerminal = Self.completionTypes.contains { type in
            normalized.contains("\"type\":\"\(type)\"")
        }
        let softTerminal = normalized.contains("\"phase\":\"final\"")
            || normalized.contains("\"phase\":\"final_answer\"")
        let contextCompaction = normalized.contains("\"type\":\"compacted\"")
            || normalized.contains("\"type\":\"context_compacted\"")
        return (
            outputActivity || inProgress,
            inProgress,
            hardTerminal || softTerminal,
            hardTerminal,
            contextCompaction
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
