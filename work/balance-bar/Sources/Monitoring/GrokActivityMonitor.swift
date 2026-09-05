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
        "agent_message_chunk"
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
        "task_backgrounded"
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
    }

    private let grokDirectory: URL
    private let clock: () -> Date
    private let processRunner: ProcessRunner
    private var sessionCache = SessionCache(scannedAt: .distantPast, url: nil, lastActivityAt: nil)
    private var processCache: (checkedAt: Date, running: Bool) = (.distantPast, false)
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

    func activityStatus() -> GrokActivityStatus {
        let processRunning = isGrokProcessRunning()
        guard processRunning else {
            return GrokActivityStatus(
                processRunning: false,
                observation: .hardTerminal,
                lastActivityAt: nil
            )
        }
        guard let session = latestSession() else {
            return GrokActivityStatus(
                processRunning: true,
                observation: .ambiguousIdle,
                lastActivityAt: nil
            )
        }
        let observation = transcriptObservation(session.url, now: clock())
        return GrokActivityStatus(
            processRunning: true,
            observation: observation.observation,
            lastActivityAt: observation.lastActivityAt ?? session.lastActivityAt
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

    private func isGrokProcessRunning() -> Bool {
        let now = clock()
        if now.timeIntervalSince(processCache.checkedAt) < 1 {
            return processCache.running
        }

        let executableURL = URL(fileURLWithPath: "/bin/ps")
        let arguments = ["-axo", "pid=,ppid=,tty=,comm=,args="]
        let result: GrokProcessResult
        do {
            result = try processRunner(executableURL, arguments)
        } catch {
            processCache = (now, false)
            return false
        }
        guard result.terminationStatus == 0 else {
            processCache = (now, false)
            return false
        }

        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let running = output.split(separator: "\n").contains { rawLine in
            Self.lineLooksLikeGrokCLI(rawLine)
        }
        processCache = (now, running)
        return running
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
                  !url.path.contains("/subagents/"),
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

    private func transcriptObservation(
        _ url: URL,
        now: Date
    ) -> (observation: ActivityMonitorObservation, lastActivityAt: Date?) {
        guard let identity = fileIdentity(atPath: url.path) else {
            return (.ambiguousIdle, nil)
        }
        if let cached = transcriptCache,
           cached.path == url.path,
           cached.size == identity.size,
           cached.modifiedAt == identity.modifiedAt,
           now.timeIntervalSince(cached.checkedAt) < 0.75 {
            return (cached.observation, cached.lastActivityAt)
        }
        func cache(
            _ observation: ActivityMonitorObservation,
            lastActivityAt: Date?
        ) -> (ActivityMonitorObservation, Date?) {
            transcriptCache = TranscriptCache(
                path: url.path,
                size: identity.size,
                modifiedAt: identity.modifiedAt,
                checkedAt: now,
                observation: observation,
                lastActivityAt: lastActivityAt
            )
            return (observation, lastActivityAt)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return cache(.ambiguousIdle, lastActivityAt: Date(timeIntervalSince1970: identity.modifiedAt))
        }
        defer { try? handle.close() }

        let tailSize: UInt64 = 192 * 1024
        let offset = identity.size > tailSize ? identity.size - tailSize : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return cache(.ambiguousIdle, lastActivityAt: Date(timeIntervalSince1970: identity.modifiedAt))
        }
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
            return cache(.ambiguousIdle, lastActivityAt: Date(timeIntervalSince1970: identity.modifiedAt))
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        let recentWrite = now.timeIntervalSince1970 - identity.modifiedAt < 15
        let fileDate = Date(timeIntervalSince1970: identity.modifiedAt)

        for line in lines.reversed() {
            guard
                let data = line.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let update = Self.sessionUpdate(from: event)
            else {
                continue
            }
            let eventDate = Self.eventDate(from: event) ?? fileDate
            if Self.activeSessionUpdates.contains(update) {
                return cache(.active, lastActivityAt: eventDate)
            }
            if Self.terminalSessionUpdates.contains(update) {
                return cache(.hardTerminal, lastActivityAt: eventDate)
            }
            if update == "user_message_chunk" {
                return cache(recentWrite ? .active : .ambiguousIdle, lastActivityAt: eventDate)
            }
            if Self.skippedSessionUpdates.contains(update) {
                continue
            }
            return cache(recentWrite ? .active : .ambiguousIdle, lastActivityAt: eventDate)
        }
        return cache(recentWrite ? .active : .ambiguousIdle, lastActivityAt: fileDate)
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
