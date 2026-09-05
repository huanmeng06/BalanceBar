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

    private struct TranscriptCache {
        let path: String
        let size: UInt64
        let modifiedAt: TimeInterval
        let checkedAt: Date
        let signal: SessionSignal
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

        static let neverStarted = SessionSignal(
            kind: .neverStarted,
            lastActivityAt: nil,
            lastUserActivityAt: nil,
            trueTurnEvidence: false
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

    /// Process presence only. Does not walk `~/.grok` sessions.
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
        var ttys: [String] = []
        var running = false
        for rawLine in output.split(separator: "\n") {
            guard Self.lineLooksLikeGrokCLI(rawLine) else { continue }
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

    static func lineLooksLikeGrokCLI<S: StringProtocol>(_ rawLine: S) -> Bool {
        let line = rawLine.lowercased()
        guard !line.contains("balancebar"),
              !line.contains("balancebar.app") else { return false }
        let fields = line.split(
            maxSplits: 4,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard fields.count >= 4 else { return false }
        let command = URL(fileURLWithPath: String(fields[3])).lastPathComponent
        let arguments = fields.count >= 5 ? String(fields[4]) : ""
        if command == "grok" || command.hasPrefix("grok-macos-") {
            return true
        }
        if arguments == "grok"
            || arguments == "grok-macos-aarch64"
            || arguments.hasPrefix("grok ")
            || arguments.hasPrefix("grok-macos-") {
            return true
        }
        return arguments.contains("/.grok/bin/grok")
            || arguments.contains("/grok-macos-")
    }

    private func combinedSessionObservation(
        now: Date
    ) -> (
        observation: ActivityMonitorObservation,
        identityActivityAt: Date?,
        trueTurnEvidence: Bool
    ) {
        let parents = activeSessionUpdateURLs()
        guard !parents.isEmpty else {
            return (.hardTerminal, nil, false)
        }

        var anyInProgress = false
        var identityActivityAt: Date?
        var trueTurnEvidence = false

        for parentURL in parents {
            let related = relatedSessionSignals(for: parentURL, now: now)
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

        return (anyInProgress ? .active : .hardTerminal, identityActivityAt, trueTurnEvidence)
    }

    private func activeSessionUpdateURLs() -> [URL] {
        let activeSessionsURL = grokDirectory.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: activeSessionsURL),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var urls: [URL] = []
        var seen: Set<String> = []
        for row in rows {
            let sessionID = row["session_id"] as? String
            let cwd = row["cwd"] as? String
            guard let sessionID, let cwd else { continue }
            let updatesURL = grokDirectory
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(Self.encodeSessionDirectoryName(cwd), isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("updates.jsonl")
            let path = updatesURL.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            urls.append(updatesURL)
        }
        return urls
    }

    private func relatedSessionSignals(
        for sessionURL: URL,
        now: Date
    ) -> [SessionSignal] {
        let sessionDirectory = sessionURL.deletingLastPathComponent()
        var signals = [transcriptSignal(sessionURL, now: now)]
        signals.append(contentsOf: durableStillRunningSignals(in: sessionDirectory))
        let subagentsDirectory = sessionDirectory
            .appendingPathComponent("subagents", isDirectory: true)
        guard FileManager.default.fileExists(atPath: subagentsDirectory.path) else {
            return signals
        }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: subagentsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            signals.append(subagentSignal(at: child, now: now))
        }
        return signals
    }

    /// Workflows, monitors, loops, and scheduler state in the considered
    /// session directory. Identity fields stay empty so this never selects
    /// the Grok tab; it only keeps task-running after parent `turn_completed`.
    private func durableStillRunningSignals(in sessionDirectory: URL) -> [SessionSignal] {
        var signals: [SessionSignal] = []
        for folderName in Self.durableStillRunningDirectories {
            let folder = sessionDirectory.appendingPathComponent(folderName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: child.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    continue
                }
                if durableWorkIsInProgress(at: child) {
                    signals.append(
                        SessionSignal(
                            kind: .inProgress,
                            lastActivityAt: nil,
                            lastUserActivityAt: nil,
                            trueTurnEvidence: false
                        )
                    )
                }
            }
        }
        return signals
    }

    private func durableWorkIsInProgress(at directory: URL) -> Bool {
        for fileName in ["state.json", "meta.json"] {
            let url = directory.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = Self.durableStatus(from: object)?.lowercased() else {
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

    private func subagentSignal(at directory: URL, now: Date) -> SessionSignal {
        let metaURL = directory.appendingPathComponent("meta.json")
        let meta = (try? Data(contentsOf: metaURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        if let status = (meta?["status"] as? String)?.lowercased(),
           Self.finishedSubagentStatuses.contains(status) {
            return SessionSignal(
                kind: .completed,
                lastActivityAt: nil,
                lastUserActivityAt: nil,
                trueTurnEvidence: false
            )
        }

        var signal = transcriptSignal(
            directory.appendingPathComponent("updates.jsonl"),
            now: now
        )
        if let childURL = childSessionUpdatesURL(from: meta) {
            let childSignal = transcriptSignal(childURL, now: now)
            signal = strongerSignal(signal, childSignal)
        }
        if meta != nil, signal.kind == .neverStarted {
            return SessionSignal(
                kind: .inProgress,
                lastActivityAt: signal.lastActivityAt,
                lastUserActivityAt: signal.lastUserActivityAt,
                trueTurnEvidence: signal.trueTurnEvidence
            )
        }
        return signal
    }

    private func childSessionUpdatesURL(from meta: [String: Any]?) -> URL? {
        guard let meta else { return nil }
        let sessionID = (meta["child_session_id"] as? String)
            ?? (meta["subagent_id"] as? String)
        let cwd = meta["child_cwd"] as? String
        guard let sessionID, !sessionID.isEmpty, let cwd, !cwd.isEmpty else {
            return nil
        }
        return grokDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(Self.encodeSessionDirectoryName(cwd), isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("updates.jsonl")
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
            trueTurnEvidence: lhs.trueTurnEvidence || rhs.trueTurnEvidence
        )
    }

    private func transcriptSignal(_ url: URL, now: Date) -> SessionSignal {
        guard let identity = fileIdentity(atPath: url.path) else {
            return .neverStarted
        }
        if let cached = transcriptCaches[url.path],
           cached.size == identity.size,
           cached.modifiedAt == identity.modifiedAt,
           now.timeIntervalSince(cached.checkedAt) < 0.75 {
            return cached.signal
        }
        func cache(_ signal: SessionSignal) -> SessionSignal {
            transcriptCaches[url.path] = TranscriptCache(
                path: url.path,
                size: identity.size,
                modifiedAt: identity.modifiedAt,
                checkedAt: now,
                signal: signal
            )
            return signal
        }
        let fileDate = Date(timeIntervalSince1970: identity.modifiedAt)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return cache(.neverStarted)
        }
        defer { try? handle.close() }

        let tailSize: UInt64 = 192 * 1024
        let offset = identity.size > tailSize ? identity.size - tailSize : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return cache(.neverStarted)
        }
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
            return cache(.neverStarted)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
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
            guard
                let data = line.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            trueTurnEvidence: lastKind == .inProgress && trueTurnEvidence
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
