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

/// Detects the terminal Grok CLI and whether the current turn is still
/// producing thoughts, tool calls, or streamed output. Process discovery and
/// session parsing are injectable so tests never touch `~/.grok`.
final class GrokActivityMonitor {
    typealias ProcessRunner = (_ executableURL: URL, _ arguments: [String]) throws -> GrokProcessResult

    private static let activeSessionUpdates: Set<String> = [
        "agent_thought_chunk",
        "tool_call",
        "tool_call_update",
        "agent_message_chunk",
        "subagent_spawned"
    ]
    private static let terminalSessionUpdates: Set<String> = [
        "turn_completed",
        "task_completed"
    ]
    private static let skippedSessionUpdates: Set<String> = [
        "plan",
        "current_mode_update",
        "session_recap",
        "compaction_checkpoint",
        "auto_compact_completed",
        "retry_state",
        "task_backgrounded",
        "subagent_finished"
    ]
    private static let finishedSubagentStatuses: Set<String> = [
        "completed",
        "failed",
        "cancelled",
        "canceled",
        "finished"
    ]

    private struct SessionCache {
        let scannedAt: Date
        let url: URL?
        let lastActivityAt: Date?
    }

    private struct TranscriptCache {
        let path: String
        let size: UInt64
        let modifiedAt: TimeInterval
        let checkedAt: Date
        let observation: ActivityMonitorObservation
        let lastActivityAt: Date?
        let lastUserActivityAt: Date?
        let trueTurnEvidence: Bool
    }

    private let grokDirectory: URL
    private let clock: () -> Date
    private let processRunner: ProcessRunner
    private var sessionCache = SessionCache(scannedAt: .distantPast, url: nil, lastActivityAt: nil)
    private let processCacheLock = NSLock()
    private var processCache: (checkedAt: Date, running: Bool, ttys: [String]) = (
        .distantPast, false, []
    )
    private var transcriptCache: TranscriptCache?

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
        guard let session = latestSession() else {
            return GrokActivityStatus(
                processRunning: true,
                observation: .ambiguousIdle,
                lastActivityAt: nil,
                ttys: process.ttys,
                trueTurnEvidence: false
            )
        }
        let combined = combinedTranscriptObservation(sessionURL: session.url, now: clock())
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

    private func latestSession() -> (url: URL, lastActivityAt: Date?)? {
        let now = clock()
        if now.timeIntervalSince(sessionCache.scannedAt) < 2 {
            return sessionCache.url.map { ($0, sessionCache.lastActivityAt) }
        }

        if let fromActiveSessions = latestSessionFromActiveSessions(now: now) {
            sessionCache = SessionCache(
                scannedAt: now,
                url: fromActiveSessions.url,
                lastActivityAt: fromActiveSessions.lastActivityAt
            )
            return fromActiveSessions
        }

        let enumerated = latestEnumeratedSession(now: now)
        sessionCache = SessionCache(
            scannedAt: now,
            url: enumerated?.url,
            lastActivityAt: enumerated?.lastActivityAt
        )
        return enumerated
    }

    private func latestSessionFromActiveSessions(
        now: Date
    ) -> (url: URL, lastActivityAt: Date?)? {
        let activeSessionsURL = grokDirectory.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: activeSessionsURL),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var latest: (url: URL, date: Date)?
        for row in rows {
            let sessionID = row["session_id"] as? String
            let cwd = row["cwd"] as? String
            guard let sessionID, let cwd else { continue }
            let encodedCWD = Self.encodeSessionDirectoryName(cwd)
            let updatesURL = grokDirectory
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(encodedCWD, isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("updates.jsonl")
            let identity = fileIdentity(atPath: updatesURL.path)
            let openedAt = (row["opened_at"] as? String).flatMap(Self.parseISO8601)
            let modified = identity.map { Date(timeIntervalSince1970: $0.modifiedAt) }
            let date = [modified, openedAt].compactMap { $0 }.max() ?? now
            if latest == nil || date > latest!.date {
                latest = (updatesURL, date)
            }
        }
        return latest.map { ($0.url, $0.date) }
    }

    private func latestEnumeratedSession(
        now: Date
    ) -> (url: URL, lastActivityAt: Date?)? {
        let sessionsDirectory = grokDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var latest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "updates.jsonl",
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            if latest == nil || modified > latest!.date {
                latest = (url, modified)
            }
        }
        return latest.map { ($0.url, $0.date) }
    }

    private func combinedTranscriptObservation(
        sessionURL: URL,
        now: Date
    ) -> (
        observation: ActivityMonitorObservation,
        identityActivityAt: Date?,
        trueTurnEvidence: Bool
    ) {
        let related = relatedTranscriptURLs(for: sessionURL)
        var observation: ActivityMonitorObservation?
        var identityActivityAt: Date?
        var parentEventActivityAt: Date?
        var trueTurnEvidence = false

        for url in related {
            let sample = transcriptObservation(url, now: now)
            trueTurnEvidence = trueTurnEvidence || sample.trueTurnEvidence
            if observation == nil {
                observation = sample.observation
                parentEventActivityAt = sample.lastActivityAt
                identityActivityAt = sample.lastUserActivityAt
            } else {
                observation = strongestObservation(observation!, sample.observation)
            }
        }

        let resolved = observation ?? .ambiguousIdle
        if let identityActivityAt {
            return (resolved, identityActivityAt, trueTurnEvidence)
        }
        if resolved.isActiveEvidence {
            // Subagent writes keep rotation alive while identity is Grok;
            // they are not proof that the user is still on the Grok tab.
            return (resolved, nil, trueTurnEvidence)
        }
        return (resolved, parentEventActivityAt, trueTurnEvidence)
    }

    private func relatedTranscriptURLs(for sessionURL: URL) -> [URL] {
        var urls = [sessionURL]
        var seen: Set<String> = [sessionURL.standardizedFileURL.path]
        func appendIfNew(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return }
            seen.insert(path)
            urls.append(url)
        }

        let subagentsDirectory = sessionURL
            .deletingLastPathComponent()
            .appendingPathComponent("subagents", isDirectory: true)
        guard FileManager.default.fileExists(atPath: subagentsDirectory.path) else {
            return urls
        }

        if let enumerator = FileManager.default.enumerator(
            at: subagentsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent == "updates.jsonl" {
                appendIfNew(url)
            }
        }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: subagentsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            let metaURL = child.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let childURL = childSessionUpdatesURL(from: row) else {
                continue
            }
            appendIfNew(childURL)
        }
        return urls
    }

    private func childSessionUpdatesURL(from meta: [String: Any]) -> URL? {
        if let status = (meta["status"] as? String)?.lowercased(),
           Self.finishedSubagentStatuses.contains(status) {
            return nil
        }
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

    private func strongestObservation(
        _ lhs: ActivityMonitorObservation,
        _ rhs: ActivityMonitorObservation
    ) -> ActivityMonitorObservation {
        func rank(_ observation: ActivityMonitorObservation) -> Int {
            switch observation {
            case .active: return 3
            case .contextCompaction: return 2
            case .ambiguousIdle: return 1
            case .hardTerminal: return 0
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private func transcriptObservation(
        _ url: URL,
        now: Date
    ) -> (
        observation: ActivityMonitorObservation,
        lastActivityAt: Date?,
        lastUserActivityAt: Date?,
        trueTurnEvidence: Bool
    ) {
        guard let identity = fileIdentity(atPath: url.path) else {
            return (.ambiguousIdle, nil, nil, false)
        }
        if let cached = transcriptCache,
           cached.path == url.path,
           cached.size == identity.size,
           cached.modifiedAt == identity.modifiedAt,
           now.timeIntervalSince(cached.checkedAt) < 0.75 {
            return (
                cached.observation,
                cached.lastActivityAt,
                cached.lastUserActivityAt,
                cached.trueTurnEvidence
            )
        }
        func cache(
            _ observation: ActivityMonitorObservation,
            lastActivityAt: Date?,
            lastUserActivityAt: Date?,
            trueTurnEvidence: Bool
        ) -> (ActivityMonitorObservation, Date?, Date?, Bool) {
            transcriptCache = TranscriptCache(
                path: url.path,
                size: identity.size,
                modifiedAt: identity.modifiedAt,
                checkedAt: now,
                observation: observation,
                lastActivityAt: lastActivityAt,
                lastUserActivityAt: lastUserActivityAt,
                trueTurnEvidence: trueTurnEvidence
            )
            return (observation, lastActivityAt, lastUserActivityAt, trueTurnEvidence)
        }
        let fileDate = Date(timeIntervalSince1970: identity.modifiedAt)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return cache(
                .ambiguousIdle,
                lastActivityAt: fileDate,
                lastUserActivityAt: nil,
                trueTurnEvidence: false
            )
        }
        defer { try? handle.close() }

        let tailSize: UInt64 = 192 * 1024
        let offset = identity.size > tailSize ? identity.size - tailSize : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return cache(
                .ambiguousIdle,
                lastActivityAt: fileDate,
                lastUserActivityAt: nil,
                trueTurnEvidence: false
            )
        }
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
            return cache(
                .ambiguousIdle,
                lastActivityAt: fileDate,
                lastUserActivityAt: nil,
                trueTurnEvidence: false
            )
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        let recentWrite = now.timeIntervalSince1970 - identity.modifiedAt < 15

        var observation: ActivityMonitorObservation?
        var lastActivityAt: Date?
        var lastUserActivityAt: Date?
        var trueTurnEvidence = false
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
            if observation == nil {
                if Self.activeSessionUpdates.contains(update) {
                    observation = .active
                    trueTurnEvidence = true
                    lastActivityAt = eventDate
                } else if Self.terminalSessionUpdates.contains(update) {
                    observation = .hardTerminal
                    lastActivityAt = eventDate
                } else if update == "user_message_chunk" {
                    observation = recentWrite ? .active : .ambiguousIdle
                    lastActivityAt = eventDate
                } else if Self.skippedSessionUpdates.contains(update) {
                    continue
                } else {
                    observation = recentWrite ? .active : .ambiguousIdle
                    lastActivityAt = eventDate
                }
            }
            if observation != nil, lastUserActivityAt != nil {
                break
            }
        }
        let resolved = observation ?? (recentWrite ? .active : .ambiguousIdle)
        return cache(
            resolved,
            lastActivityAt: lastActivityAt ?? fileDate,
            lastUserActivityAt: lastUserActivityAt,
            trueTurnEvidence: trueTurnEvidence
        )
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

    private static func parseISO8601(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: value)
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
