import Foundation
import Darwin

struct GrokProcessResult {
    let standardOutput: Data
    let terminationStatus: Int32
}

struct GrokActivityStatus: Equatable {
    let processRunning: Bool
    let observation: ActivityMonitorObservation
    let lastActivityAt: Date?
    let ttys: [String]
    let trueTurnEvidence: Bool
}

/// Detects the terminal Grok CLI and whether any considered session is still
/// in progress. Process discovery and session parsing are injectable so tests
/// never touch `~/.grok`.
final class GrokActivityMonitor {
    typealias ProcessRunner = (_ executableURL: URL, _ arguments: [String]) throws -> GrokProcessResult

    private static let trueTurnSessionUpdates: Set<String> = [
        "agent_thought_chunk",
        "tool_call",
        "tool_call_update",
        "agent_message_chunk",
        "subagent_spawned"
    ]
    private static let terminalSessionUpdates: Set<String> = [
        "turn_completed"
    ]
    private static let noiseSessionUpdates: Set<String> = [
        "session_recap",
        "compaction_checkpoint",
        "auto_compact_completed",
        "current_mode_update",
        "image_dropped",
        "image_compressed",
        "subagent_finished",
        "workflow_updated"
    ]
    private static let finishedDurableStatuses: Set<String> = [
        "completed",
        "complete",
        "failed",
        "cancelled",
        "canceled",
        "stopped",
        "finished"
    ]
    private static let inProgressDurableStatuses: Set<String> = [
        "active",
        "running",
        "paused",
        "pausing"
    ]
    private static let finishedSubagentStatuses: Set<String> = [
        "completed",
        "failed",
        "cancelled",
        "canceled",
        "finished"
    ]
    private static let durableStillRunningDirectories = [
        "workflows",
        "monitors",
        "loops",
        "scheduler"
    ]
    private static let childWorkDirectoryNames = durableStillRunningDirectories + ["subagents"]

    private struct TranscriptCache {
        let size: UInt64
        let modifiedAt: TimeInterval
        let signal: SessionSignal
    }

    private struct ChildJSONCache {
        let size: UInt64
        let modifiedAt: TimeInterval
        let parsed: Bool
        let status: String?
        let childSessionID: String?
        let childCWD: String?
    }

    private struct SessionSignal {
        enum Kind {
            case neverStarted
            case inProgress
            case completed
        }

        let kind: Kind
        let lastActivityAt: Date?
        let lastUserActivityAt: Date?
        let trueTurnEvidence: Bool
        /// Transcript is `.inProgress` only because unmatched `task_backgrounded`
        /// remained after a terminal last update such as `turn_completed`.
        let unmatchedBackgroundOnly: Bool

        static let neverStarted = SessionSignal(
            kind: .neverStarted,
            lastActivityAt: nil,
            lastUserActivityAt: nil,
            trueTurnEvidence: false,
            unmatchedBackgroundOnly: false
        )
    }

    private let grokDirectory: URL
    private let clock: () -> Date
    private let processRunner: ProcessRunner
    private let processCacheLock = NSLock()
    private var processCache: (checkedAt: Date, running: Bool, ttys: [String]) = (
        .distantPast, false, []
    )
    private var transcriptCaches: [String: TranscriptCache] = [:]
    private var childJSONCaches: [String: ChildJSONCache] = [:]
    private(set) var transcriptReadCount = 0
    private(set) var transcriptParseCount = 0
    private(set) var relatedSessionSignalsCount = 0
    private(set) var childJSONReadCount = 0

    init(
        grokDirectory: URL? = nil,
        clock: @escaping () -> Date = { Date() },
        processRunner: ProcessRunner? = nil
    ) {
        self.grokDirectory = grokDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok", isDirectory: true)
        self.clock = clock
        self.processRunner = processRunner ?? Self.runProcess
    }

    func status() -> (processRunning: Bool, taskRunning: Bool) {
        let status = activityStatus()
        return (status.processRunning, status.observation.legacyIsTaskRunning)
    }

    /// Process presence only. Reads `active_sessions.json` pids for bare
    /// `agent` confirmation and does not walk transcripts.
    func processPresence() -> (running: Bool, ttys: [String]) {
        grokProcessState()
    }

    func activityStatus() -> GrokActivityStatus {
        let process = grokProcessState()
        guard process.running else {
            return GrokActivityStatus(
                processRunning: false,
                observation: .hardTerminal,
                lastActivityAt: nil,
                ttys: [],
                trueTurnEvidence: false
            )
        }

        let combined = combinedSessionObservation(now: clock())
        return GrokActivityStatus(
            processRunning: true,
            observation: combined.observation,
            lastActivityAt: combined.identityActivityAt,
            ttys: process.ttys,
            trueTurnEvidence: combined.trueTurnEvidence
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) throws -> GrokProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GrokProcessResult(
            standardOutput: data,
            terminationStatus: process.terminationStatus
        )
    }

    private func grokProcessState() -> (running: Bool, ttys: [String]) {
        let now = clock()
        processCacheLock.lock()
        if now.timeIntervalSince(processCache.checkedAt) < 1 {
            let cached = (processCache.running, processCache.ttys)
            processCacheLock.unlock()
            return cached
        }
        processCacheLock.unlock()

        let executableURL = URL(fileURLWithPath: "/bin/ps")
        let arguments = ["-axo", "pid=,ppid=,tty=,comm=,args="]
        let result: GrokProcessResult
        do {
            result = try processRunner(executableURL, arguments)
        } catch {
            storeProcessCache(checkedAt: now, running: false, ttys: [])
            return (false, [])
        }
        guard result.terminationStatus == 0 else {
            storeProcessCache(checkedAt: now, running: false, ttys: [])
            return (false, [])
        }

        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let confirmedAgentPIDs = Self.liveAgentPIDs(in: grokDirectory)
        var ttys: [String] = []
        var running = false
        for rawLine in output.split(separator: "\n") {
            guard Self.lineLooksLikeGrokCLI(
                rawLine,
                confirmedAgentPIDs: confirmedAgentPIDs
            ) else { continue }
            running = true
            if let tty = TerminalCLIProcessRecord.parse(rawLine)?.tty {
                ttys.append(tty)
            }
        }
        storeProcessCache(checkedAt: now, running: running, ttys: ttys)
        return (running, ttys)
    }

    private func storeProcessCache(checkedAt: Date, running: Bool, ttys: [String]) {
        processCacheLock.lock()
        processCache = (checkedAt, running, ttys)
        processCacheLock.unlock()
    }

    static func lineLooksLikeGrokCLI<S: StringProtocol>(
        _ rawLine: S,
        confirmedAgentPIDs: Set<Int32> = []
    ) -> Bool {
        let line = rawLine.lowercased()
        guard !line.contains("balancebar"),
              !line.contains("balancebar.app") else { return false }
        let fields = line.split(
            maxSplits: 4,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard fields.count >= 4 else { return false }
        // `ps -axo comm=` right-pads the command column; leftover spaces land in args.
        let commandPath = String(fields[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        let command = URL(fileURLWithPath: commandPath).lastPathComponent
        let arguments = fields.count >= 5
            ? String(fields[4]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if command == "grok" || command.hasPrefix("grok-macos-") {
            return true
        }
        if arguments == "grok"
            || arguments == "grok-macos-aarch64"
            || arguments.hasPrefix("grok ")
            || arguments.hasPrefix("grok-macos-") {
            return true
        }
        if arguments.contains("/.grok/bin/grok")
            || arguments.contains("/grok-macos-") {
            return true
        }
        if commandPath.contains("/.grok/bin/agent")
            || arguments.contains("/.grok/bin/agent") {
            return true
        }
        if command == "agent" && arguments.contains("grok-macos") {
            return true
        }
        guard command == "agent",
              arguments == "agent" || arguments.hasPrefix("agent ") else {
            return false
        }
        let tty = TerminalCLIProcessRecord.normalizeTTY(String(fields[2]))
        guard let tty, tty.hasPrefix("ttys"),
              let pid = Int32(fields[0]),
              confirmedAgentPIDs.contains(pid) else {
            return false
        }
        return true
    }

    static func liveAgentPIDs(in grokDirectory: URL) -> Set<Int32> {
        let url = grokDirectory.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return liveAgentPIDs(fromActiveSessionsJSON: data)
    }

    static func liveAgentPIDs(fromActiveSessionsJSON data: Data) -> Set<Int32> {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var pids: Set<Int32> = []
        for row in rows {
            guard let pid = int32PID(row["pid"]), pid > 0 else { continue }
            pids.insert(pid)
        }
        return pids
    }

    private static func int32PID(_ value: Any?) -> Int32? {
        if let number = value as? NSNumber {
            return Int32(exactly: number.int64Value)
        }
        if let string = value as? String {
            return Int32(string)
        }
        return nil
    }

    private struct ActiveSessionRow {
        let sessionID: String
        let cwd: String
        let openedAt: Date?
        let updatesURL: URL
    }

    private func combinedSessionObservation(
        now: Date
    ) -> (
        observation: ActivityMonitorObservation,
        identityActivityAt: Date?,
        trueTurnEvidence: Bool
    ) {
        let listed = activeSessionRows()
        guard !listed.isEmpty else {
            return (.hardTerminal, nil, false)
        }

        var anyInProgress = false
        var identityActivityAt: Date?
        var trueTurnEvidence = false
        var listedIDsByCWD: [String: Set<String>] = [:]
        var liveOpenedDates: [Date] = []
        var allOpenedDates: [Date] = []

        for row in listed {
            listedIDsByCWD[row.cwd, default: []].insert(row.sessionID)
            if let openedAt = row.openedAt {
                allOpenedDates.append(openedAt)
            }
            let related = relatedSessionSignals(for: row.updatesURL.path, now: now)
            let parent = related.first ?? .neverStarted
            if parent.kind != .neverStarted, let openedAt = row.openedAt {
                liveOpenedDates.append(openedAt)
            }
            for signal in related {
                trueTurnEvidence = trueTurnEvidence || signal.trueTurnEvidence
                if signal.kind == .inProgress {
                    anyInProgress = true
                }
                if let userActivity = signal.lastUserActivityAt {
                    if let current = identityActivityAt {
                        identityActivityAt = max(current, userActivity)
                    } else {
                        identityActivityAt = userActivity
                    }
                }
            }
        }

        if !anyInProgress {
            let earliestLiveOpenedAt = liveOpenedDates.min() ?? allOpenedDates.min()
            cwdGroupScan: for (cwd, listedIDs) in listedIDsByCWD {
                for sibling in siblingSessionDirectories(cwd: cwd, excluding: listedIDs) {
                    let siblingProgress = unlistedSiblingProgress(
                        sessionPath: sibling,
                        now: now,
                        earliestLiveOpenedAt: earliestLiveOpenedAt
                    )
                    if siblingProgress.inProgress {
                        anyInProgress = true
                        trueTurnEvidence = trueTurnEvidence || siblingProgress.trueTurnEvidence
                        break cwdGroupScan
                    }
                }
            }
        }

        return (anyInProgress ? .active : .hardTerminal, identityActivityAt, trueTurnEvidence)
    }

    private func activeSessionRows() -> [ActiveSessionRow] {
        let activeSessionsURL = grokDirectory.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: activeSessionsURL),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var listed: [ActiveSessionRow] = []
        var seen: Set<String> = []
        for row in rows {
            let sessionID = row["session_id"] as? String
            let cwd = row["cwd"] as? String
            guard let sessionID, let cwd else { continue }
            let updatesURL = sessionUpdatesURL(sessionID: sessionID, cwd: cwd)
            let path = updatesURL.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            listed.append(
                ActiveSessionRow(
                    sessionID: sessionID,
                    cwd: cwd,
                    openedAt: Self.parseOpenedAt(row["opened_at"]),
                    updatesURL: updatesURL
                )
            )
        }
        return listed
    }

    private func sessionUpdatesURL(sessionID: String, cwd: String) -> URL {
        grokDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(Self.encodeSessionDirectoryName(cwd), isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("updates.jsonl")
    }

    /// Direct children of one cwd group. Does not walk `~/.grok/sessions`.
    private func siblingSessionDirectories(cwd: String, excluding listedIDs: Set<String>) -> [String] {
        let groupPath = Self.joinedPath(
            Self.joinedPath(grokDirectory.path, "sessions"),
            Self.encodeSessionDirectoryName(cwd)
        )
        guard isDirectory(atPath: groupPath) else {
            return []
        }
        return directoryContents(atPath: groupPath).compactMap { name in
            guard !listedIDs.contains(name) else { return nil }
            let childPath = Self.joinedPath(groupPath, name)
            guard isDirectory(atPath: childPath) else { return nil }
            return childPath
        }
    }

    /// Unlisted siblings keep running when child work is unfinished, or when
    /// the last in-progress activity is not earlier than live `opened_at`.
    /// A completed parent whose only leftover is unmatched `task_backgrounded`
    /// is not live work.
    private func unlistedSiblingProgress(
        sessionPath: String,
        now: Date,
        earliestLiveOpenedAt: Date?
    ) -> (inProgress: Bool, trueTurnEvidence: Bool) {
        let updatesPath = Self.joinedPath(sessionPath, "updates.jsonl")
        // Childless parents whose updates+meta precede live opened_at cannot
        // keep the group running; skip related child/transcript work.
        if isStaleChildlessParent(
            sessionPath: sessionPath,
            updatesPath: updatesPath,
            earliestLiveOpenedAt: earliestLiveOpenedAt
        ) {
            return (false, false)
        }
        let related = relatedSessionSignals(for: updatesPath, now: now)
        let parent = related.first ?? .neverStarted
        let unfinishedChild = related.dropFirst().contains { $0.kind == .inProgress }
        if unfinishedChild {
            return (true, related.contains { $0.trueTurnEvidence })
        }
        guard parent.kind == .inProgress, !parent.unmatchedBackgroundOnly else {
            return (false, false)
        }
        guard let earliestLiveOpenedAt else {
            return (false, false)
        }
        let recency = siblingRecencyDate(
            parent: parent,
            sessionPath: sessionPath,
            updatesPath: updatesPath
        )
        guard let recency, recency >= earliestLiveOpenedAt else {
            return (false, false)
        }
        return (true, parent.trueTurnEvidence)
    }

    private func isStaleChildlessParent(
        sessionPath: String,
        updatesPath: String,
        earliestLiveOpenedAt: Date?
    ) -> Bool {
        guard let earliestLiveOpenedAt,
              let identity = fileIdentity(atPath: updatesPath) else {
            return false
        }
        guard Date(timeIntervalSince1970: identity.modifiedAt) < earliestLiveOpenedAt else {
            return false
        }
        let metaDate = fileIdentity(atPath: Self.joinedPath(sessionPath, "meta.json"))
            .map { Date(timeIntervalSince1970: $0.modifiedAt) } ?? .distantPast
        guard metaDate < earliestLiveOpenedAt else {
            return false
        }
        return !hasChildWorkContainers(sessionPath: sessionPath)
    }

    private func hasChildWorkContainers(sessionPath: String) -> Bool {
        for name in Self.childWorkDirectoryNames {
            if fileIdentity(atPath: Self.joinedPath(sessionPath, name)) != nil {
                return true
            }
        }
        return false
    }

    private func siblingRecencyDate(
        parent: SessionSignal,
        sessionPath: String,
        updatesPath: String
    ) -> Date? {
        var candidates: [Date] = []
        if let lastActivityAt = parent.lastActivityAt {
            candidates.append(lastActivityAt)
        }
        if let identity = fileIdentity(atPath: updatesPath) {
            candidates.append(Date(timeIntervalSince1970: identity.modifiedAt))
        }
        if let identity = fileIdentity(atPath: Self.joinedPath(sessionPath, "meta.json")) {
            candidates.append(Date(timeIntervalSince1970: identity.modifiedAt))
        }
        return candidates.max()
    }

    private static func parseOpenedAt(_ value: Any?) -> Date? {
        if let timestamp = value as? Double {
            return Date(timeIntervalSince1970: timestamp)
        }
        if let timestamp = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func relatedSessionSignals(
        for updatesPath: String,
        now: Date
    ) -> [SessionSignal] {
        relatedSessionSignalsCount += 1
        let sessionPath = Self.parentPath(updatesPath)
        var signals = [transcriptSignal(updatesPath, now: now)]
        signals.append(contentsOf: durableStillRunningSignals(in: sessionPath))
        let subagentsPath = Self.joinedPath(sessionPath, "subagents")
        guard isDirectory(atPath: subagentsPath) else {
            return signals
        }
        for name in directoryContents(atPath: subagentsPath) {
            let childPath = Self.joinedPath(subagentsPath, name)
            guard isDirectory(atPath: childPath) else { continue }
            signals.append(subagentSignal(at: childPath, now: now))
        }
        return signals
    }

    /// Workflows, monitors, loops, and scheduler state in the considered
    /// session directory. Identity fields stay empty so this never selects
    /// the Grok tab; it only keeps task-running after parent `turn_completed`.
    private func durableStillRunningSignals(in sessionPath: String) -> [SessionSignal] {
        var signals: [SessionSignal] = []
        for folderName in Self.durableStillRunningDirectories {
            let folderPath = Self.joinedPath(sessionPath, folderName)
            guard isDirectory(atPath: folderPath) else { continue }
            for name in directoryContents(atPath: folderPath) {
                let childPath = Self.joinedPath(folderPath, name)
                guard isDirectory(atPath: childPath) else { continue }
                if durableWorkIsInProgress(at: childPath) {
                    signals.append(
                        SessionSignal(
                            kind: .inProgress,
                            lastActivityAt: nil,
                            lastUserActivityAt: nil,
                            trueTurnEvidence: false,
                            unmatchedBackgroundOnly: false
                        )
                    )
                }
            }
        }
        return signals
    }

    private func durableWorkIsInProgress(at directoryPath: String) -> Bool {
        for fileName in ["state.json", "meta.json"] {
            guard let cached = cachedChildJSON(atPath: Self.joinedPath(directoryPath, fileName)),
                  cached.parsed,
                  let status = cached.status?.lowercased() else {
                continue
            }
            if Self.inProgressDurableStatuses.contains(status) {
                return true
            }
            if Self.finishedDurableStatuses.contains(status) {
                return false
            }
        }
        return false
    }

    private static func durableStatus(from object: [String: Any]) -> String? {
        if let state = object["state"] as? [String: Any],
           let status = state["status"] as? String {
            return status
        }
        return object["status"] as? String
    }

    private func subagentSignal(at directoryPath: String, now: Date) -> SessionSignal {
        let cachedMeta = cachedChildJSON(atPath: Self.joinedPath(directoryPath, "meta.json"))
        if let status = cachedMeta?.status?.lowercased(),
           cachedMeta?.parsed == true,
           Self.finishedSubagentStatuses.contains(status) {
            return SessionSignal(
                kind: .completed,
                lastActivityAt: nil,
                lastUserActivityAt: nil,
                trueTurnEvidence: false,
                unmatchedBackgroundOnly: false
            )
        }

        var signal = transcriptSignal(
            Self.joinedPath(directoryPath, "updates.jsonl"),
            now: now
        )
        if let childPath = childSessionUpdatesPath(from: cachedMeta) {
            signal = strongerSignal(signal, transcriptSignal(childPath, now: now))
        }
        if cachedMeta?.parsed == true, signal.kind == .neverStarted {
            return SessionSignal(
                kind: .inProgress,
                lastActivityAt: signal.lastActivityAt,
                lastUserActivityAt: signal.lastUserActivityAt,
                trueTurnEvidence: signal.trueTurnEvidence,
                unmatchedBackgroundOnly: false
            )
        }
        return signal
    }

    private func childSessionUpdatesPath(from cachedMeta: ChildJSONCache?) -> String? {
        guard let cachedMeta, cachedMeta.parsed else { return nil }
        let sessionID = cachedMeta.childSessionID
        let cwd = cachedMeta.childCWD
        guard let sessionID, !sessionID.isEmpty, let cwd, !cwd.isEmpty else {
            return nil
        }
        return sessionUpdatesURL(sessionID: sessionID, cwd: cwd).path
    }

    private func strongerSignal(_ lhs: SessionSignal, _ rhs: SessionSignal) -> SessionSignal {
        func rank(_ kind: SessionSignal.Kind) -> Int {
            switch kind {
            case .inProgress: return 2
            case .completed: return 1
            case .neverStarted: return 0
            }
        }
        let winner = rank(lhs.kind) >= rank(rhs.kind) ? lhs : rhs
        let lastActivity = [lhs.lastActivityAt, rhs.lastActivityAt].compactMap { $0 }.max()
        let lastUser = [lhs.lastUserActivityAt, rhs.lastUserActivityAt].compactMap { $0 }.max()
        return SessionSignal(
            kind: winner.kind,
            lastActivityAt: lastActivity,
            lastUserActivityAt: lastUser,
            trueTurnEvidence: lhs.trueTurnEvidence || rhs.trueTurnEvidence,
            unmatchedBackgroundOnly: winner.kind == .inProgress && winner.unmatchedBackgroundOnly
        )
    }

    private func transcriptSignal(_ path: String, now _: Date) -> SessionSignal {
        guard let identity = fileIdentity(atPath: path) else {
            transcriptCaches.removeValue(forKey: path)
            return .neverStarted
        }
        if let cached = transcriptCaches[path],
           cached.size == identity.size,
           cached.modifiedAt == identity.modifiedAt {
            return cached.signal
        }
        func cache(_ signal: SessionSignal) -> SessionSignal {
            transcriptCaches[path] = TranscriptCache(
                size: identity.size,
                modifiedAt: identity.modifiedAt,
                signal: signal
            )
            return signal
        }
        let fileDate = Date(timeIntervalSince1970: identity.modifiedAt)
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path, isDirectory: false)) else {
            return .neverStarted
        }
        defer { try? handle.close() }

        let tailSize: UInt64 = 192 * 1024
        let offset = identity.size > tailSize ? identity.size - tailSize : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return .neverStarted
        }
        transcriptReadCount += 1
        guard let data = try? handle.read(upToCount: Int(tailSize)) else {
            return .neverStarted
        }
        // Split bytes, not grapheme clusters; a tail may begin inside UTF-8.
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }

        var lastKind: SessionSignal.Kind?
        var lastActivityAt: Date?
        var lastUserActivityAt: Date?
        var trueTurnEvidence = false
        var unmatchedBackgroundIDs = Set<String>()
        var completedBackgroundIDs = Set<String>()
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            transcriptParseCount += 1
            guard
                let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let update = Self.sessionUpdate(from: event)
            else {
                continue
            }
            let eventDate = Self.eventDate(from: event) ?? fileDate
            if update == "user_message_chunk", lastUserActivityAt == nil {
                lastUserActivityAt = eventDate
            }
            if update == "task_completed" {
                if let taskID = Self.backgroundTaskID(from: event, update: update) {
                    completedBackgroundIDs.insert(taskID)
                }
                continue
            }
            if update == "task_backgrounded" {
                if let taskID = Self.backgroundTaskID(from: event, update: update),
                   !completedBackgroundIDs.contains(taskID) {
                    unmatchedBackgroundIDs.insert(taskID)
                }
                continue
            }
            if lastKind == nil {
                if Self.noiseSessionUpdates.contains(update) {
                    continue
                }
                lastActivityAt = eventDate
                if Self.terminalSessionUpdates.contains(update) {
                    lastKind = .completed
                    trueTurnEvidence = false
                } else {
                    lastKind = .inProgress
                    trueTurnEvidence = Self.trueTurnSessionUpdates.contains(update)
                }
            }
        }
        let hasUnmatchedBackground = !unmatchedBackgroundIDs.isEmpty
        let unmatchedBackgroundOnly = lastKind == .completed && hasUnmatchedBackground
        let kind: SessionSignal.Kind
        if lastKind == .inProgress || hasUnmatchedBackground {
            kind = .inProgress
        } else {
            kind = lastKind ?? .neverStarted
        }
        let signal = SessionSignal(
            kind: kind,
            lastActivityAt: lastActivityAt,
            lastUserActivityAt: lastUserActivityAt,
            trueTurnEvidence: lastKind == .inProgress && trueTurnEvidence,
            unmatchedBackgroundOnly: unmatchedBackgroundOnly
        )
        return cache(signal)
    }

    private static func backgroundTaskID(
        from event: [String: Any],
        update: String
    ) -> String? {
        let payload = updatePayload(from: event)
        switch update {
        case "task_backgrounded":
            return stringValue(payload["task_id"])
                ?? stringValue(payload["tool_call_id"])
        case "task_completed":
            if let snapshot = payload["task_snapshot"] as? [String: Any] {
                return stringValue(snapshot["task_id"])
                    ?? stringValue(snapshot["tool_call_id"])
            }
            return stringValue(payload["task_id"])
                ?? stringValue(payload["tool_call_id"])
        default:
            return nil
        }
    }

    private static func updatePayload(from event: [String: Any]) -> [String: Any] {
        if let params = event["params"] as? [String: Any],
           let update = params["update"] as? [String: Any] {
            return update
        }
        if let update = event["update"] as? [String: Any] {
            return update
        }
        return event
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func sessionUpdate(from object: [String: Any]) -> String? {
        if let params = object["params"] as? [String: Any],
           let update = params["update"] as? [String: Any],
           let value = update["sessionUpdate"] as? String {
            return value
        }
        return object["sessionUpdate"] as? String ?? object["type"] as? String
    }

    private static func eventDate(from object: [String: Any]) -> Date? {
        if let timestamp = object["timestamp"] as? Double {
            return Date(timeIntervalSince1970: timestamp)
        }
        if let timestamp = object["timestamp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        return nil
    }

    private func cachedChildJSON(atPath path: String) -> ChildJSONCache? {
        guard let identity = fileIdentity(atPath: path) else {
            childJSONCaches.removeValue(forKey: path)
            return nil
        }
        if let cached = childJSONCaches[path],
           cached.size == identity.size,
           cached.modifiedAt == identity.modifiedAt {
            return cached
        }
        childJSONReadCount += 1
        let object = FileManager.default.contents(atPath: path).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let cached = ChildJSONCache(
            size: identity.size,
            modifiedAt: identity.modifiedAt,
            parsed: object != nil,
            status: object.flatMap(Self.durableStatus(from:)),
            childSessionID: (object?["child_session_id"] as? String)
                ?? (object?["subagent_id"] as? String),
            childCWD: object?["child_cwd"] as? String
        )
        childJSONCaches[path] = cached
        return cached
    }

    private func directoryContents(atPath path: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
    }

    private func isDirectory(atPath path: String) -> Bool {
        var value = stat()
        guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return false }
        return (value.st_mode & S_IFMT) == S_IFDIR
    }

    private static func joinedPath(_ directory: String, _ component: String) -> String {
        if directory.isEmpty { return component }
        if directory.hasSuffix("/") {
            return directory + component
        }
        return directory + "/" + component
    }

    private static func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        if slash == path.startIndex {
            return "/"
        }
        return String(path[..<slash])
    }

    static func encodeSessionDirectoryName(_ cwd: String) -> String {
        var encoded = ""
        for scalar in cwd.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "."
                || scalar == "_"
                || scalar == "~" {
                encoded.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    encoded += String(format: "%%%02X", byte)
                }
            }
        }
        return encoded
    }

    private func fileIdentity(atPath path: String) -> (size: UInt64, modifiedAt: TimeInterval)? {
        var value = stat()
        guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
        let modifiedAt = TimeInterval(value.st_mtimespec.tv_sec)
            + (TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (UInt64(max(0, value.st_size)), modifiedAt)
    }
}
