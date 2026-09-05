import Foundation
import Darwin

struct ClaudeProcessResult {
    let standardOutput: Data
    let terminationStatus: Int32
}

struct ClaudeActivityStatus: Equatable {
    let processRunning: Bool
    let observation: ActivityMonitorObservation
    let lastActivityAt: Date?
    let ttys: [String]
    let trueTurnEvidence: Bool
}

final class ClaudeCodeActivityMonitor {
    typealias ProcessRunner = (_ executableURL: URL, _ arguments: [String]) throws -> ClaudeProcessResult

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
        let trueTurnEvidence: Bool
    }

    private let projectsDirectory: URL
    private let clock: () -> Date
    private let processRunner: ProcessRunner
    private var sessionCache = SessionCache(scannedAt: .distantPast, url: nil, lastActivityAt: nil)
    private var processCache: (checkedAt: Date, running: Bool, ttys: [String]) = (
        .distantPast, false, []
    )
    private var transcriptCache: TranscriptCache?

    init(
        projectsDirectory: URL? = nil,
        clock: @escaping () -> Date = { Date() },
        processRunner: ProcessRunner? = nil
    ) {
        self.projectsDirectory = projectsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
        self.clock = clock
        self.processRunner = processRunner ?? Self.runProcess
    }

    func status() -> (processRunning: Bool, taskRunning: Bool) {
        let status = activityStatus()
        return (status.processRunning, status.observation.legacyIsTaskRunning)
    }

    func activityStatus() -> ClaudeActivityStatus {
        let process = claudeProcessState()
        guard process.running else {
            return ClaudeActivityStatus(
                processRunning: false,
                observation: .hardTerminal,
                lastActivityAt: nil,
                ttys: [],
                trueTurnEvidence: false
            )
        }
        guard let session = latestMainSession() else {
            return ClaudeActivityStatus(
                processRunning: true,
                observation: .ambiguousIdle,
                lastActivityAt: nil,
                ttys: process.ttys,
                trueTurnEvidence: false
            )
        }
        let sample = transcriptObservation(session.url, now: clock())
        return ClaudeActivityStatus(
            processRunning: true,
            observation: sample.observation,
            lastActivityAt: session.lastActivityAt,
            ttys: process.ttys,
            trueTurnEvidence: sample.trueTurnEvidence
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) throws -> ClaudeProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Drain stdout while `ps` is still running. Waiting first can
        // deadlock when a long process list fills the pipe buffer, which
        // would also block balance rendering on the shared monitor queue.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ClaudeProcessResult(
            standardOutput: data,
            terminationStatus: process.terminationStatus
        )
    }

    private func claudeProcessState() -> (running: Bool, ttys: [String]) {
        let now = clock()
        if now.timeIntervalSince(processCache.checkedAt) < 1 {
            return (processCache.running, processCache.ttys)
        }

        let executableURL = URL(fileURLWithPath: "/bin/ps")
        let arguments = ["-axo", "pid=,ppid=,tty=,comm=,args="]
        let result: ClaudeProcessResult
        do {
            result = try processRunner(executableURL, arguments)
        } catch {
            processCache = (now, false, [])
            return (false, [])
        }
        guard result.terminationStatus == 0 else {
            processCache = (now, false, [])
            return (false, [])
        }

        // A single unrelated process may contain non-UTF-8 bytes in its
        // arguments. Decode lossily so that one malformed row does not hide
        // an otherwise valid `Claude` process from detection.
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        var ttys: [String] = []
        var running = false
        for rawLine in output.split(separator: "\n") {
            guard Self.lineLooksLikeClaudeCLI(rawLine) else { continue }
            running = true
            if let tty = TerminalCLIProcessRecord.parse(rawLine)?.tty {
                ttys.append(tty)
            }
        }
        processCache = (now, running, ttys)
        return (running, ttys)
    }

    static func lineLooksLikeClaudeCLI<S: StringProtocol>(_ rawLine: S) -> Bool {
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
        return command == "claude"
            || arguments.hasPrefix("claude ")
            || arguments.contains("/claude ")
            || arguments.contains("/claude-code/")
            || arguments.contains("@anthropic-ai/claude-code")
    }

    private func latestMainSession() -> (url: URL, lastActivityAt: Date?)? {
        let now = clock()
        if now.timeIntervalSince(sessionCache.scannedAt) < 2 {
            return sessionCache.url.map { ($0, sessionCache.lastActivityAt) }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            sessionCache = SessionCache(scannedAt: now, url: nil, lastActivityAt: nil)
            return nil
        }

        var latest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
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
        sessionCache = SessionCache(
            scannedAt: now,
            url: latest?.url,
            lastActivityAt: latest?.date
        )
        return latest.map { ($0.url, $0.date) }
    }

    private func transcriptObservation(
        _ url: URL,
        now: Date
    ) -> (observation: ActivityMonitorObservation, trueTurnEvidence: Bool) {
        guard let identity = fileIdentity(atPath: url.path) else {
            return (.ambiguousIdle, false)
        }
        let sizeValue = identity.size
        let modifiedValue = identity.modifiedAt
        if let cached = transcriptCache,
           cached.path == url.path,
           cached.size == sizeValue,
           cached.modifiedAt == modifiedValue,
           now.timeIntervalSince(cached.checkedAt) < 0.75 {
            return (cached.observation, cached.trueTurnEvidence)
        }
        func cache(
            _ observation: ActivityMonitorObservation,
            trueTurnEvidence: Bool = false
        ) -> (ActivityMonitorObservation, Bool) {
            transcriptCache = TranscriptCache(
                path: url.path,
                size: sizeValue,
                modifiedAt: modifiedValue,
                checkedAt: now,
                observation: observation,
                trueTurnEvidence: trueTurnEvidence
            )
            return (observation, trueTurnEvidence)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return cache(.ambiguousIdle)
        }
        defer { try? handle.close() }

        let tailSize: UInt64 = 192 * 1024
        let fileSize = sizeValue
        let offset = fileSize > tailSize ? fileSize - tailSize : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return cache(.ambiguousIdle)
        }
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
            return cache(.ambiguousIdle)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        let recentWrite = now.timeIntervalSince1970 - modifiedValue < 15

        for line in lines.reversed() {
            guard
                let data = line.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = event["type"] as? String
            else {
                continue
            }

            // Claude Code records Esc / interrupt as a synthetic user event
            // with `interruptedMessageId`. It is terminal for the current turn,
            // even though the Claude process and interactive session remain open.
            if event["interruptedMessageId"] != nil {
                return cache(.hardTerminal)
            }

            if type == "assistant", let message = event["message"] as? [String: Any] {
                let stopReason = message["stop_reason"] as? String
                if stopReason == "end_turn" || stopReason == "stop_sequence" {
                    return cache(.hardTerminal)
                }
                if stopReason == "tool_use" {
                    return cache(.active, trueTurnEvidence: true)
                }
                if let content = message["content"] as? [[String: Any]],
                   content.contains(where: {
                       let contentType = $0["type"] as? String
                       return contentType == "thinking" || contentType == "tool_use"
                   }) {
                    return cache(.active, trueTurnEvidence: true)
                }
                return cache(recentWrite ? .active : .ambiguousIdle)
            }

            if type == "user", let message = event["message"] as? [String: Any] {
                if let content = message["content"] as? [[String: Any]],
                   !content.isEmpty,
                   content.allSatisfy({ ($0["type"] as? String) == "tool_result" }) {
                    continue
                }
                return cache(recentWrite ? .active : .ambiguousIdle)
            }

            if type == "progress" || type == "queue-operation" {
                return cache(recentWrite ? .active : .ambiguousIdle)
            }
        }
        return cache(recentWrite ? .active : .ambiguousIdle)
    }

    private func fileIdentity(atPath path: String) -> (size: UInt64, modifiedAt: TimeInterval)? {
        var value = stat()
        guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
        let modifiedAt = TimeInterval(value.st_mtimespec.tv_sec)
            + (TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (UInt64(max(0, value.st_size)), modifiedAt)
    }
}
