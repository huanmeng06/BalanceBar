import AppKit
import Darwin
import Foundation

struct TerminalCLIProcessRecord: Equatable {
    let pid: Int32
    let ppid: Int32
    let tty: String?
    let command: String
    let arguments: String

    static func parse<S: StringProtocol>(_ rawLine: S) -> TerminalCLIProcessRecord? {
        let fields = rawLine.split(
            maxSplits: 4,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard fields.count >= 4,
              let pid = Int32(fields[0]),
              let ppid = Int32(fields[1]) else {
            return nil
        }
        return TerminalCLIProcessRecord(
            pid: pid,
            ppid: ppid,
            tty: normalizeTTY(String(fields[2])),
            command: String(fields[3]),
            arguments: fields.count >= 5 ? String(fields[4]) : ""
        )
    }

    static func normalizeTTY(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("/dev/") {
            value = String(value.dropFirst(5))
        }
        if value.isEmpty || value == "??" || value == "-" {
            return nil
        }
        return value
    }
}

struct TerminalCLIProcessSnapshot: Equatable {
    let parentByPID: [Int32: Int32]
    let grok: [TerminalCLIProcessRecord]
    let claude: [TerminalCLIProcessRecord]

    var grokTTYs: Set<String> {
        Set(grok.compactMap(\.tty))
    }

    var claudeTTYs: Set<String> {
        Set(claude.compactMap(\.tty))
    }

    init(psOutput: String) {
        var parentByPID: [Int32: Int32] = [:]
        var grok: [TerminalCLIProcessRecord] = []
        var claude: [TerminalCLIProcessRecord] = []
        for rawLine in psOutput.split(separator: "\n") {
            let line = String(rawLine)
            guard let record = TerminalCLIProcessRecord.parse(line) else { continue }
            parentByPID[record.pid] = record.ppid
            if GrokActivityMonitor.lineLooksLikeGrokCLI(line) {
                grok.append(record)
            } else if ClaudeCodeActivityMonitor.lineLooksLikeClaudeCLI(line) {
                claude.append(record)
            }
        }
        self.parentByPID = parentByPID
        self.grok = grok
        self.claude = claude
    }

    static func load() -> TerminalCLIProcessSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,comm=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return TerminalCLIProcessSnapshot(
                psOutput: String(decoding: data, as: UTF8.self)
            )
        } catch {
            return nil
        }
    }

    func belongsToTerminal(pid: Int32, terminalPID: Int32) -> Bool {
        var current = pid
        var seen = Set<Int32>()
        while current > 0, seen.insert(current).inserted {
            if current == terminalPID { return true }
            guard let parent = parentByPID[current], parent != current else {
                return false
            }
            current = parent
        }
        return false
    }

    func cliProcesses(underTerminalPID terminalPID: Int32) -> [TerminalCLIProcessRecord] {
        (grok + claude).filter { belongsToTerminal(pid: $0.pid, terminalPID: terminalPID) }
    }
}

enum TerminalFrontmostTTY {
    static func appleScriptSource(bundleIdentifier: String?) -> String? {
        switch (bundleIdentifier ?? "").lowercased() {
        case "com.apple.terminal":
            return """
            tell application id "com.apple.Terminal"
                if not (exists front window) then return ""
                return tty of selected tab of front window
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                try
                    return tty of current session of current window
                on error
                    return ""
                end try
            end tell
            """
        default:
            return nil
        }
    }

    static func resolve(
        bundleIdentifier: String?,
        terminalPID: Int32?,
        snapshot: TerminalCLIProcessSnapshot,
        appleScriptTTY: String?,
        ttyIODate: (String) -> Date?
    ) -> String? {
        if let selected = TerminalCLIProcessRecord.normalizeTTY(appleScriptTTY) {
            return selected
        }
        guard let terminalPID else { return nil }
        let belonging = snapshot.cliProcesses(underTerminalPID: terminalPID)
            .filter { $0.tty != nil }
        if belonging.count == 1 {
            return belonging[0].tty
        }
        guard belonging.count > 1 else { return nil }
        return belonging.max { lhs, rhs in
            let left = lhs.tty.flatMap(ttyIODate) ?? .distantPast
            let right = rhs.tty.flatMap(ttyIODate) ?? .distantPast
            return left < right
        }?.tty
    }

    static func selectedTTY(application: NSRunningApplication?) -> String? {
        guard let source = appleScriptSource(bundleIdentifier: application?.bundleIdentifier) else {
            return nil
        }
        return TerminalCLIProcessRecord.normalizeTTY(runAppleScript(source))
    }

    static func resolve(
        application: NSRunningApplication?,
        snapshot: TerminalCLIProcessSnapshot
    ) -> String? {
        return resolve(
            bundleIdentifier: application?.bundleIdentifier,
            terminalPID: application.map(\.processIdentifier),
            snapshot: snapshot,
            appleScriptTTY: selectedTTY(application: application),
            ttyIODate: ioDate(forTTY:)
        )
    }

    static func ioDate(forTTY tty: String) -> Date? {
        let path = tty.hasPrefix("/") ? tty : "/dev/\(tty)"
        var value = stat()
        guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
        let atime = TimeInterval(value.st_atimespec.tv_sec)
            + (TimeInterval(value.st_atimespec.tv_nsec) / 1_000_000_000)
        let mtime = TimeInterval(value.st_mtimespec.tv_sec)
            + (TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000)
        return Date(timeIntervalSince1970: max(atime, mtime))
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}
