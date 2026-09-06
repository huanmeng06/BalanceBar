import AppKit
import ApplicationServices
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

    init(psOutput: String, confirmedAgentPIDs: Set<Int32> = []) {
        var parentByPID: [Int32: Int32] = [:]
        var grok: [TerminalCLIProcessRecord] = []
        var claude: [TerminalCLIProcessRecord] = []
        for rawLine in psOutput.split(separator: "\n") {
            let line = String(rawLine)
            guard let record = TerminalCLIProcessRecord.parse(line) else { continue }
            parentByPID[record.pid] = record.ppid
            if GrokActivityMonitor.lineLooksLikeGrokCLI(
                line,
                confirmedAgentPIDs: confirmedAgentPIDs
            ) {
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
            let grokDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok", isDirectory: true)
            return TerminalCLIProcessSnapshot(
                psOutput: String(decoding: data, as: UTF8.self),
                confirmedAgentPIDs: GrokActivityMonitor.liveAgentPIDs(in: grokDirectory)
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

    /// Map a selected-tab process (often zsh) onto the unique grok/claude TTY
    /// under that terminal window. The CLI may be the pid itself or a child.
    func uniqueCLITTY(focusedPID: Int32, terminalPID: Int32) -> String? {
        let belonging = cliProcesses(underTerminalPID: terminalPID)
        var matched = belonging.filter { belongsToTerminal(pid: $0.pid, terminalPID: focusedPID) }
        if matched.isEmpty {
            matched = belonging.filter { belongsToTerminal(pid: focusedPID, terminalPID: $0.pid) }
        }
        let ttys = Set(matched.compactMap(\.tty))
        return ttys.count == 1 ? ttys.first : nil
    }
}

enum TerminalPTYFDActivity {
    static func ttyName(path: String, rdev: UInt32) -> String? {
        let normalized = TerminalCLIProcessRecord.normalizeTTY(path)
        if let normalized, normalized.hasPrefix("ttys") {
            return normalized
        }
        guard let normalized else { return nil }
        guard normalized == "ptmx" || normalized.hasPrefix("pty") else {
            return nil
        }
        let minor = Int(rdev & 0x00ff_ffff)
        guard (0..<1000).contains(minor) else { return nil }
        return String(format: "ttys%03d", minor)
    }
}

struct TerminalTTYWinsize: Equatable {
    var rows: UInt16
    var cols: UInt16
}

/// Focused TTY for one frontmost terminal PID. Continuous PTY output is not
/// a focus change; the latch is dropped when that PID is no longer frontmost.
struct TerminalTTYFocusLatch: Equatable {
    var terminalPID: Int32?
    var tty: String?
    var quietCounts: [String: Int] = [:]
    var previousFDOffsets: [String: Int64] = [:]
    var previousIODates: [String: Date] = [:]
    var previousWinsizes: [String: TerminalTTYWinsize] = [:]
}

/// One Apple Event: selected-tab TTY, PID, and title.
struct TerminalSelectedTabSignal: Equatable {
    var tty: String?
    var pid: Int32?
    var title: String?
}

enum TerminalAppleScriptStatus: String, Equatable {
    case skippedExecuting = "skipped_executing"
    case skippedBackoff = "skipped_backoff"
    case timeout = "timeout"
    case failure = "failure"
    case empty = "empty"
    case value = "ok"
}

enum TerminalAppleEventPermission: Equatable {
    case unknown
    case allowed
    case denied
}

enum TerminalFocusHint {
    /// Unique grok XOR claude only. Do not match gro, cloud, or cloud code.
    static func client(fromWindowTitle title: String?) -> AssistantClient? {
        guard let title else { return nil }
        let lower = title.lowercased()
        let hasGrok = lower.contains("grok")
        let hasClaude = lower.contains("claude")
        if hasGrok && !hasClaude { return .grok }
        if hasClaude && !hasGrok { return .claude }
        return nil
    }

    static func uniqueTTY(
        for client: AssistantClient,
        terminalPID: Int32,
        snapshot: TerminalCLIProcessSnapshot
    ) -> String? {
        let records: [TerminalCLIProcessRecord]
        switch client {
        case .grok:
            records = snapshot.grok
        case .claude:
            records = snapshot.claude
        case .codex:
            return nil
        }
        let ttys = Set(
            records
                .filter { snapshot.belongsToTerminal(pid: $0.pid, terminalPID: terminalPID) }
                .compactMap(\.tty)
        )
        return ttys.count == 1 ? ttys.first : nil
    }

    static func focusedKittyTTY(
        lsJSON: Data,
        snapshot: TerminalCLIProcessSnapshot,
        terminalPID: Int32
    ) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: lsJSON) else {
            return nil
        }
        guard let osWindows = root as? [Any] else { return nil }
        for osWindow in osWindows {
            guard let os = osWindow as? [String: Any],
                  os["is_focused"] as? Bool == true,
                  let tabs = os["tabs"] as? [Any] else {
                continue
            }
            for tab in tabs {
                guard let tabObject = tab as? [String: Any],
                      tabObject["is_focused"] as? Bool == true,
                      let windows = tabObject["windows"] as? [Any] else {
                    continue
                }
                for window in windows {
                    guard let windowObject = window as? [String: Any],
                          windowObject["is_focused"] as? Bool == true,
                          let tty = tty(
                            fromKittyWindow: windowObject,
                            snapshot: snapshot,
                            terminalPID: terminalPID
                          ) else {
                        continue
                    }
                    return tty
                }
            }
        }
        return nil
    }

    private static func tty(
        fromKittyWindow window: [String: Any],
        snapshot: TerminalCLIProcessSnapshot,
        terminalPID: Int32
    ) -> String? {
        let belonging = snapshot.cliProcesses(underTerminalPID: terminalPID)
        if let tty = TerminalCLIProcessRecord.normalizeTTY(window["tty"] as? String),
           belonging.contains(where: { $0.tty == tty }) {
            return tty
        }

        var pids: [Int32] = []
        if let pid = int32(window["pid"]) {
            pids.append(pid)
        }
        let processes = window["foreground_processes"] as? [[String: Any]] ?? []
        for process in processes {
            if let pid = int32(process["pid"]) {
                pids.append(pid)
            }
        }
        let matchedTTYs = Set(belonging.filter { pids.contains($0.pid) }.compactMap(\.tty))
        if matchedTTYs.count == 1 {
            return matchedTTYs.first
        }

        var grok = false
        var claude = false
        for process in processes {
            let command = ((process["cmdline"] as? [Any]) ?? [])
                .compactMap { $0 as? String }
                .joined(separator: " ")
                .lowercased()
            let name = URL(fileURLWithPath: command.split(separator: " ").first.map(String.init) ?? "").lastPathComponent
            if name == "grok" || name.hasPrefix("grok-macos-") || command.contains("/.grok/bin/grok") {
                grok = true
            }
            if name == "claude" || command.contains("/claude ") || command.contains("@anthropic-ai/claude-code") {
                claude = true
            }
        }
        if grok != claude {
            return uniqueTTY(
                for: grok ? .grok : .claude,
                terminalPID: terminalPID,
                snapshot: snapshot
            )
        }
        return nil
    }

    private static func int32(_ value: Any?) -> Int32? {
        if let value = value as? Int32 { return value }
        if let value = value as? Int { return Int32(value) }
        if let value = value as? NSNumber { return value.int32Value }
        return nil
    }
}

enum TerminalFrontmostTTY {
    private static let procPIDListFDs: Int32 = 1
    private static let procPIDFDVNodePathInfo: Int32 = 2
    private static let procFDTypeVNode: UInt32 = 1
    private static let procFDInfoSize = 8
    private static let vnodeFDInfoWithPathSize = 1200
    private static let fileOffsetOffset = 8
    private static let rdevOffset = 140
    private static let pathOffset = 176

    private static let latchLock = NSLock()
    private static var focusLatch = TerminalTTYFocusLatch()
    private static let scriptCacheLock = NSLock()
    private static var compiledAppleScripts: [String: NSAppleScript] = [:]
    private static var appleScriptSkipUntil: Date?
    private static let appleScriptBackoffInterval: TimeInterval = 2
    private static let appleScriptQueue = DispatchQueue(
        label: "local.balancebar.terminal-applescript"
    )
    static let appleScriptTimeout: TimeInterval = 0.25
    private static var appleScriptExecuting = false
    private static var lastAppleScriptStatus: TerminalAppleScriptStatus = .empty
    private static var lastAppleScriptDuration: TimeInterval = 0
    private static var lastAppleScriptRaw: String?
    private static let identityLogLock = NSLock()
    private static var lastIdentityLogAt = Date.distantPast
    private static var lastIdentityLogSignature = ""
    private static var terminalAppleEventPermission: TerminalAppleEventPermission = .unknown
    private static var didAskTerminalAppleEventPermission = false
    static let appleEventNotPermittedStatus: OSStatus = -1743

    static func usesSelectedTabAppleScript(bundleIdentifier: String?) -> Bool {
        let bundle = (bundleIdentifier ?? "").lowercased()
        switch bundle {
        case "com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty":
            return true
        default:
            return bundle.hasSuffix(".ghostty")
        }
    }

    static func permission(fromAppleEventStatus status: OSStatus) -> TerminalAppleEventPermission {
        switch status {
        case noErr:
            return .allowed
        case appleEventNotPermittedStatus:
            return .denied
        default:
            return .unknown
        }
    }

    static func shouldSendAppleEvents(_ permission: TerminalAppleEventPermission) -> Bool {
        permission == .allowed
    }

    static func appleScriptSource(
        bundleIdentifier: String?,
        applicationPath: String? = nil
    ) -> String? {
        let bundle = (bundleIdentifier ?? "").lowercased()
        switch bundle {
        case "com.apple.terminal":
            return terminalAppleScriptSource(applicationPath: applicationPath)
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                try
                    set tabTTY to ""
                    set tabPID to ""
                    set tabTitle to ""
                    try
                        set tabTTY to tty of current session of current window as string
                    end try
                    try
                        set tabTitle to name of current session of current window as string
                    end try
                    return tabTTY & linefeed & tabPID & linefeed & tabTitle
                on error
                    return ""
                end try
            end tell
            """
        case "com.mitchellh.ghostty":
            return ghosttyAppleScriptSource(applicationPath: applicationPath)
        default:
            if bundle.hasSuffix(".ghostty") {
                return ghosttyAppleScriptSource(applicationPath: applicationPath)
            }
            return nil
        }
    }

    /// Official Terminal.app one-shot: `tty` / `custom title` of
    /// `selected tab of front window`. Never concatenate an empty triple,
    /// and never `as string` a value that may be missing.
    private static func terminalAppleScriptSource(applicationPath: String?) -> String {
        let path = applicationPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = terminalSelectedTabBody()
        let nameTell = """
        try
            tell application "Terminal"
        \(body)
            end tell
        on error errMsg number errNum
            set msg to errMsg as text
            if (count of msg) > 80 then set msg to text 1 thru 80 of msg
            return "ERR" & linefeed & (errNum as text) & linefeed & msg
        end try
        """
        guard !path.isEmpty else { return nameTell }
        let escapedPath = escapeAppleScriptString(path)
        return """
        try
            tell application "\(escapedPath)"
        \(body)
            end tell
        on error errMsg number errNum
            try
                tell application "Terminal"
        \(body)
                end tell
            on error errMsg2 number errNum2
                set msg to errMsg2 as text
                if (count of msg) > 80 then set msg to text 1 thru 80 of msg
                return "ERR" & linefeed & (errNum2 as text) & linefeed & msg
            end try
        end try
        """
    }

    private static func terminalSelectedTabBody() -> String {
        """
                if (count of windows) is 0 then
                    return "ERR" & linefeed & "no_windows" & linefeed & ""
                end if
                if not (exists front window) then
                    return "ERR" & linefeed & "no_front_window" & linefeed & ""
                end if
                set tabRef to selected tab of front window
                set tabTTY to tty of tabRef
                set tabPID to ""
                set tabTitle to custom title of tabRef
                if tabTTY is missing value then set tabTTY to ""
                if tabTitle is missing value then set tabTitle to ""
                if tabTitle is "" then
                    set tabTitle to name of front window
                    if tabTitle is missing value then set tabTitle to ""
                end if
                if tabTTY is "" and tabTitle is "" then
                    return "ERR" & linefeed & "empty_tab" & linefeed & ""
                end if
                return (tabTTY as text) & linefeed & (tabPID as text) & linefeed & (tabTitle as text)
        """
    }

    /// Ghostty's dictionary identifiers only compile against a real app
    /// target. Bundle-id tell is a compile-time -1728 when Launch Services
    /// cannot see Ghostty, so the cache key includes the absolute path.
    private static func ghosttyAppleScriptSource(applicationPath: String?) -> String? {
        let path = applicationPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        let escapedPath = escapeAppleScriptString(path)
        let body = ghosttySelectedTabBody()
        return """
        try
            tell application "\(escapedPath)"
        \(body)
            end tell
        on error errMsg number errNum
            try
                tell application "Ghostty"
        \(body)
                end tell
            on error errMsg2 number errNum2
                set msg to errMsg2 as text
                if (count of msg) > 80 then set msg to text 1 thru 80 of msg
                return "ERR" & linefeed & (errNum2 as text) & linefeed & msg
            end try
        end try
        """
    }

    /// Official one-shot: `focused terminal of selected tab of front window`.
    /// Empty windows is the `macos-applescript` gate. Never concatenate an
    /// empty triple, and never `as string` a value that may be missing.
    private static func ghosttySelectedTabBody() -> String {
        """
                if (count of windows) is 0 then
                    return "ERR" & linefeed & "no_windows" & linefeed & "macos-applescript"
                end if
                if not (exists front window) then
                    return "ERR" & linefeed & "no_front_window" & linefeed & ""
                end if
                set term to focused terminal of selected tab of front window
                set tabTTY to tty of term
                set tabPID to pid of term
                set tabTitle to name of term
                if tabTTY is missing value then set tabTTY to ""
                if tabPID is missing value then set tabPID to ""
                if tabTitle is missing value then set tabTitle to ""
                if tabTitle is "" then
                    set tabTitle to name of front window
                    if tabTitle is missing value then set tabTitle to ""
                end if
                if tabTTY is "" and tabPID is "" and tabTitle is "" then
                    return "ERR" & linefeed & "empty_term" & linefeed & ""
                end if
                return (tabTTY as text) & linefeed & (tabPID as text) & linefeed & (tabTitle as text)
        """
    }

    private static func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func isGhosttyBundle(_ bundleIdentifier: String?) -> Bool {
        let bundle = (bundleIdentifier ?? "").lowercased()
        return bundle == "com.mitchellh.ghostty" || bundle.hasSuffix(".ghostty")
    }

    static func appleScriptApplicationPath(
        bundleIdentifier: String?,
        application: NSRunningApplication?
    ) -> String? {
        if let path = application?.bundleURL?.path,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        guard isGhosttyBundle(bundleIdentifier) else { return nil }
        let running = NSWorkspace.shared.runningApplications.first { candidate in
            isGhosttyBundle(candidate.bundleIdentifier)
        }
        let path = running?.bundleURL?.path.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    static func parseSelectedTabSignal(_ raw: String?) -> TerminalSelectedTabSignal {
        guard let raw else { return TerminalSelectedTabSignal() }
        if isAppleScriptErrorPayload(raw) { return TerminalSelectedTabSignal() }
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return TerminalSelectedTabSignal() }
        let parts = raw.split(
            separator: "\n",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        let tty = parts.isEmpty
            ? nil
            : TerminalCLIProcessRecord.normalizeTTY(sanitizedAppleScriptField(String(parts[0])))
        let pid: Int32?
        if parts.count > 1 {
            let pidText = sanitizedAppleScriptField(String(parts[1])) ?? ""
            if let value = Int32(pidText), value > 0 {
                pid = value
            } else {
                pid = nil
            }
        } else {
            pid = nil
        }
        let title = parts.count > 2 ? sanitizedAppleScriptField(String(parts[2])) : nil
        return TerminalSelectedTabSignal(tty: tty, pid: pid, title: title)
    }

    /// `"\\n\\n"` and other whitespace-only AppleScript results are empty,
    /// not a successful selected-tab signal.
    static func isAppleScriptPayloadEmpty(_ raw: String?) -> Bool {
        guard let raw else { return true }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isAppleScriptErrorPayload(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.hasPrefix("ERR")
    }

    static func appleScriptErrorCode(_ raw: String?) -> String? {
        guard isAppleScriptErrorPayload(raw), let raw else { return nil }
        let parts = raw.split(
            separator: "\n",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count >= 2 else { return nil }
        let code = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    private static func sanitizedAppleScriptField(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.caseInsensitiveCompare("missing value") == .orderedSame {
            return nil
        }
        return trimmed
    }

    static func discardLatch() {
        latchLock.lock()
        focusLatch = TerminalTTYFocusLatch()
        latchLock.unlock()
    }

    static func resolve(
        bundleIdentifier: String?,
        terminalPID: Int32?,
        snapshot: TerminalCLIProcessSnapshot,
        appleScriptTTY: String?,
        ttyIODate: (String) -> Date?,
        ttyFDOffset: (String) -> Int64? = { _ in nil },
        ttyWinsize: (String) -> TerminalTTYWinsize? = { _ in nil },
        ipcTTY: String? = nil,
        windowTitle: String? = nil,
        latch: inout TerminalTTYFocusLatch
    ) -> String? {
        if latch.terminalPID != terminalPID {
            latch = TerminalTTYFocusLatch(terminalPID: terminalPID)
        }
        guard let terminalPID else { return nil }

        let belonging = snapshot.cliProcesses(underTerminalPID: terminalPID)
            .filter { $0.tty != nil }
        let candidateTTYs = belonging.compactMap(\.tty)
        let signal = focusSignal(
            appleScriptTTY: appleScriptTTY,
            belonging: belonging,
            candidateTTYs: candidateTTYs,
            terminalPID: terminalPID,
            snapshot: snapshot,
            ipcTTY: ipcTTY,
            windowTitle: windowTitle,
            ttyIODate: ttyIODate,
            ttyFDOffset: ttyFDOffset,
            ttyWinsize: ttyWinsize,
            latch: latch
        )
        ingest(
            candidateTTYs: candidateTTYs,
            ttyIODate: ttyIODate,
            ttyFDOffset: ttyFDOffset,
            ttyWinsize: ttyWinsize,
            latch: &latch
        )
        if let signal {
            latch.tty = signal
            return signal
        }
        if let latched = latch.tty, candidateTTYs.contains(latched) {
            return latched
        }
        latch.tty = nil
        return nil
    }

    static func selectedTTY(application: NSRunningApplication?) -> String? {
        let bundle = application?.bundleIdentifier
        return selectedTabSignal(
            bundleIdentifier: bundle,
            applicationPath: appleScriptApplicationPath(
                bundleIdentifier: bundle,
                application: application
            )
        ).tty
    }

    static func selectedTabSignal(
        bundleIdentifier: String?,
        applicationPath: String? = nil
    ) -> TerminalSelectedTabSignal {
        guard usesSelectedTabAppleScript(bundleIdentifier: bundleIdentifier) else {
            return TerminalSelectedTabSignal()
        }
        return parseSelectedTabSignal(
            runCachedAppleScript(
                bundleIdentifier: bundleIdentifier,
                applicationPath: applicationPath
            )
        )
    }

    /// Classify a selected-tab TTY even when that client has several TTYs
    /// under the same terminal process. Title XOR still requires uniqueness.
    static func uniquelyClassifiedTTY(
        _ rawTTY: String?,
        grokTTYs: Set<String>,
        claudeTTYs: Set<String>
    ) -> String? {
        guard let rawTTY,
              let field = sanitizedAppleScriptField(rawTTY),
              let tty = TerminalCLIProcessRecord.normalizeTTY(field) else { return nil }
        let grok = grokTTYs.contains(tty)
        let claude = claudeTTYs.contains(tty)
        return grok != claude ? tty : nil
    }

    static func resolve(
        application: NSRunningApplication?,
        snapshot: TerminalCLIProcessSnapshot
    ) -> String? {
        resolve(
            application: application,
            grokTTYs: snapshot.grokTTYs,
            claudeTTYs: snapshot.claudeTTYs,
            loadSnapshot: { snapshot }
        ).tty
    }

    static func resolve(
        application: NSRunningApplication?,
        grokTTYs: Set<String>,
        claudeTTYs: Set<String>,
        loadSnapshot: @escaping () -> TerminalCLIProcessSnapshot?
    ) -> (tty: String?, snapshot: TerminalCLIProcessSnapshot?) {
        let started = Date()
        let bundle = application?.bundleIdentifier
        let signal: TerminalSelectedTabSignal
        if usesSelectedTabAppleScript(bundleIdentifier: bundle) {
            signal = selectedTabSignal(
                bundleIdentifier: bundle,
                applicationPath: appleScriptApplicationPath(
                    bundleIdentifier: bundle,
                    application: application
                )
            )
        } else {
            recordAppleScriptStatus(.empty, duration: 0)
            signal = TerminalSelectedTabSignal()
        }
        var snapshot: TerminalCLIProcessSnapshot?
        var snapshotLoaded = false
        let loadOnce: () -> TerminalCLIProcessSnapshot? = {
            if !snapshotLoaded {
                snapshot = loadSnapshot()
                snapshotLoaded = true
            }
            return snapshot
        }

        latchLock.lock()
        var latch = focusLatch
        latchLock.unlock()
        let focused = resolveFocus(
            bundleIdentifier: bundle,
            terminalPID: application?.processIdentifier,
            grokTTYs: grokTTYs,
            claudeTTYs: claudeTTYs,
            appleScriptTTY: signal.tty,
            appleScriptPID: signal.pid,
            appleScriptTitle: signal.title,
            loadSnapshot: loadOnce,
            ttyIODate: ioDate(forTTY:),
            ttyFDOffsets: {
                guard let pid = application?.processIdentifier else { return [:] }
                return ptyFDOffsets(terminalPID: pid)
            },
            ttyWinsize: { winsize(forTTY: $0) },
            ipcTTY: {
                guard let snap = loadOnce() else { return nil }
                return focusedSurfaceTTY(
                    bundleIdentifier: bundle,
                    terminalPID: application?.processIdentifier,
                    application: application,
                    snapshot: snap
                )
            },
            latch: &latch
        )
        latchLock.lock()
        focusLatch = latch
        let latchedTTY = focusLatch.tty
        latchLock.unlock()
        logIdentityTick(
            signal: signal,
            focusedTTY: focused.tty,
            latchTTY: latchedTTY,
            grokTTYs: grokTTYs.union(snapshot?.grokTTYs ?? []),
            claudeTTYs: claudeTTYs.union(snapshot?.claudeTTYs ?? []),
            duration: Date().timeIntervalSince(started)
        )
        return (focused.tty, snapshot)
    }

    static func resolveFocus(
        bundleIdentifier: String?,
        terminalPID: Int32?,
        grokTTYs: Set<String>,
        claudeTTYs: Set<String>,
        appleScriptTTY: String?,
        appleScriptPID: Int32?,
        appleScriptTitle: String? = nil,
        loadSnapshot: @escaping () -> TerminalCLIProcessSnapshot?,
        ttyIODate: @escaping (String) -> Date?,
        ttyFDOffsets: () -> [String: Int64],
        ttyWinsize: @escaping (String) -> TerminalTTYWinsize?,
        ipcTTY: () -> String?,
        latch: inout TerminalTTYFocusLatch
    ) -> (tty: String?, loadedSnapshot: Bool, probedSurface: Bool) {
        if let selected = uniquelyClassifiedTTY(
            appleScriptTTY,
            grokTTYs: grokTTYs,
            claudeTTYs: claudeTTYs
        ) {
            applySelectedTTY(selected, terminalPID: terminalPID, latch: &latch)
            return (selected, false, false)
        }

        var snapshot: TerminalCLIProcessSnapshot?
        var loadedSnapshot = false
        let snapshotValue: () -> TerminalCLIProcessSnapshot? = {
            if !loadedSnapshot {
                snapshot = loadSnapshot()
                loadedSnapshot = true
            }
            return snapshot
        }

        if let selected = TerminalCLIProcessRecord.normalizeTTY(appleScriptTTY),
           let snap = snapshotValue() {
            let grok = grokTTYs.union(snap.grokTTYs)
            let claude = claudeTTYs.union(snap.claudeTTYs)
            if uniquelyClassifiedTTY(selected, grokTTYs: grok, claudeTTYs: claude) != nil {
                applySelectedTTY(selected, terminalPID: terminalPID, latch: &latch)
                return (selected, true, false)
            }
        }

        if let appleScriptPID, let terminalPID {
            if let snap = snapshotValue(),
               let mapped = snap.uniqueCLITTY(focusedPID: appleScriptPID, terminalPID: terminalPID) {
                let grok = grokTTYs.union(snap.grokTTYs)
                let claude = claudeTTYs.union(snap.claudeTTYs)
                if uniquelyClassifiedTTY(mapped, grokTTYs: grok, claudeTTYs: claude) != nil {
                    applySelectedTTY(mapped, terminalPID: terminalPID, latch: &latch)
                    return (mapped, true, false)
                }
            }
        }

        if let terminalPID,
           let snap = snapshotValue(),
           let titleTTY = uniqueTitleTTY(
            appleScriptTitle,
            terminalPID: terminalPID,
            snapshot: snap,
            grokTTYs: grokTTYs,
            claudeTTYs: claudeTTYs
           ) {
            applySelectedTTY(titleTTY, terminalPID: terminalPID, latch: &latch)
            return (titleTTY, true, false)
        }

        guard let snap = snapshotValue() else {
            if usesSelectedTabAppleScript(bundleIdentifier: bundleIdentifier) {
                releaseUnconfirmedLatch(terminalPID: terminalPID, latch: &latch)
            } else if latch.terminalPID != terminalPID {
                latch = TerminalTTYFocusLatch(terminalPID: terminalPID)
            }
            return (nil, loadedSnapshot, false)
        }

        let belonging = terminalPID.map {
            snap.cliProcesses(underTerminalPID: $0).filter { $0.tty != nil }
        } ?? []
        if belonging.count == 1, let tty = belonging[0].tty {
            applySelectedTTY(tty, terminalPID: terminalPID, latch: &latch)
            return (tty, true, false)
        }

        let candidateTTYs = belonging.compactMap(\.tty)
        let appleScriptSupported = usesSelectedTabAppleScript(bundleIdentifier: bundleIdentifier)
        let bundle = (bundleIdentifier ?? "").lowercased()
        let needsIPC = bundle.contains("kitty") && candidateTTYs.count > 1
        let allowOneShot = !appleScriptSupported && candidateTTYs.count > 1
        if appleScriptSupported && !needsIPC {
            releaseUnconfirmedLatch(terminalPID: terminalPID, latch: &latch)
            return (nil, true, false)
        }
        guard needsIPC || allowOneShot else {
            return (
                retainedLatchTTY(candidateTTYs: candidateTTYs, terminalPID: terminalPID, latch: &latch),
                true,
                false
            )
        }

        let offsets = allowOneShot ? ttyFDOffsets() : [:]
        var winsizes: [String: TerminalTTYWinsize] = [:]
        if allowOneShot {
            for tty in Set(candidateTTYs) {
                if let size = ttyWinsize(tty) {
                    winsizes[tty] = size
                }
            }
        }
        let ipc = needsIPC ? ipcTTY() : nil
        let tty = resolve(
            bundleIdentifier: bundleIdentifier,
            terminalPID: terminalPID,
            snapshot: snap,
            appleScriptTTY: nil,
            ttyIODate: ttyIODate,
            ttyFDOffset: { offsets[$0] },
            ttyWinsize: { winsizes[$0] },
            ipcTTY: ipc,
            windowTitle: nil,
            latch: &latch
        )
        return (tty, true, true)
    }

    private static func applySelectedTTY(
        _ tty: String,
        terminalPID: Int32?,
        latch: inout TerminalTTYFocusLatch
    ) {
        if latch.terminalPID != terminalPID {
            latch = TerminalTTYFocusLatch(terminalPID: terminalPID)
        }
        latch.tty = tty
    }

    private static func uniqueTitleTTY(
        _ title: String?,
        terminalPID: Int32,
        snapshot: TerminalCLIProcessSnapshot,
        grokTTYs: Set<String>,
        claudeTTYs: Set<String>
    ) -> String? {
        guard let title = title.flatMap(sanitizedAppleScriptField),
              let client = TerminalFocusHint.client(fromWindowTitle: title),
              let titleTTY = TerminalFocusHint.uniqueTTY(
                for: client,
                terminalPID: terminalPID,
                snapshot: snapshot
              ) else {
            return nil
        }
        let grok = grokTTYs.union(snapshot.grokTTYs)
        let claude = claudeTTYs.union(snapshot.claudeTTYs)
        return uniquelyClassifiedTTY(titleTTY, grokTTYs: grok, claudeTTYs: claude)
    }

    private static func releaseUnconfirmedLatch(
        terminalPID: Int32?,
        latch: inout TerminalTTYFocusLatch
    ) {
        if latch.terminalPID != terminalPID {
            latch = TerminalTTYFocusLatch(terminalPID: terminalPID)
            return
        }
        latch.tty = nil
    }

    private static func retainedLatchTTY(
        candidateTTYs: [String],
        terminalPID: Int32?,
        latch: inout TerminalTTYFocusLatch
    ) -> String? {
        if latch.terminalPID != terminalPID {
            latch = TerminalTTYFocusLatch(terminalPID: terminalPID)
        }
        if let latched = latch.tty, candidateTTYs.contains(latched) {
            return latched
        }
        latch.tty = nil
        return nil
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

    static func winsize(forTTY tty: String) -> TerminalTTYWinsize? {
        let path = tty.hasPrefix("/") ? tty : "/dev/\(tty)"
        let fd = path.withCString {
            Darwin.open($0, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        }
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var size = Darwin.winsize()
        guard Darwin.ioctl(fd, TIOCGWINSZ, &size) == 0 else { return nil }
        guard size.ws_row > 0 || size.ws_col > 0 else { return nil }
        return TerminalTTYWinsize(rows: size.ws_row, cols: size.ws_col)
    }

    private static func focusSignal(
        appleScriptTTY: String?,
        belonging: [TerminalCLIProcessRecord],
        candidateTTYs: [String],
        terminalPID: Int32,
        snapshot: TerminalCLIProcessSnapshot,
        ipcTTY: String?,
        windowTitle: String?,
        ttyIODate: (String) -> Date?,
        ttyFDOffset: (String) -> Int64?,
        ttyWinsize: (String) -> TerminalTTYWinsize?,
        latch: TerminalTTYFocusLatch
    ) -> String? {
        if let selected = TerminalCLIProcessRecord.normalizeTTY(appleScriptTTY) {
            return selected
        }
        if belonging.count == 1 {
            return belonging[0].tty
        }
        guard belonging.count > 1 else { return nil }
        if let ipc = TerminalCLIProcessRecord.normalizeTTY(ipcTTY),
           candidateTTYs.contains(ipc) {
            return ipc
        }
        if let client = TerminalFocusHint.client(fromWindowTitle: windowTitle),
           let titleTTY = TerminalFocusHint.uniqueTTY(
            for: client,
            terminalPID: terminalPID,
            snapshot: snapshot
           ),
           candidateTTYs.contains(titleTTY) {
            return titleTTY
        }
        return oneShotFocusTTY(
            candidateTTYs: candidateTTYs,
            ttyIODate: ttyIODate,
            ttyFDOffset: ttyFDOffset,
            ttyWinsize: ttyWinsize,
            latch: latch
        )
    }

    private static func oneShotFocusTTY(
        candidateTTYs: [String],
        ttyIODate: (String) -> Date?,
        ttyFDOffset: (String) -> Int64?,
        ttyWinsize: (String) -> TerminalTTYWinsize?,
        latch: TerminalTTYFocusLatch
    ) -> String? {
        let hits = candidateTTYs.filter { tty in
            (latch.quietCounts[tty] ?? 0) >= 2
                && (
                    didChange(ttyFDOffset(tty), previous: latch.previousFDOffsets[tty])
                        || didChange(ttyIODate(tty), previous: latch.previousIODates[tty])
                        || didChange(ttyWinsize(tty), previous: latch.previousWinsizes[tty])
                )
        }
        return hits.count == 1 ? hits[0] : nil
    }

    private static func ingest(
        candidateTTYs: [String],
        ttyIODate: (String) -> Date?,
        ttyFDOffset: (String) -> Int64?,
        ttyWinsize: (String) -> TerminalTTYWinsize?,
        latch: inout TerminalTTYFocusLatch
    ) {
        for tty in candidateTTYs {
            let offset = ttyFDOffset(tty)
            let ioDate = ttyIODate(tty)
            let size = ttyWinsize(tty)
            let fdChanged = didChange(offset, previous: latch.previousFDOffsets[tty])
            let ioChanged = didChange(ioDate, previous: latch.previousIODates[tty])
            let sizeChanged = didChange(size, previous: latch.previousWinsizes[tty])
            let initialized = latch.previousFDOffsets[tty] != nil
                || latch.previousIODates[tty] != nil
                || latch.previousWinsizes[tty] != nil
            if fdChanged || ioChanged || sizeChanged {
                latch.quietCounts[tty] = 0
            } else if initialized {
                latch.quietCounts[tty, default: 0] += 1
            } else {
                latch.quietCounts[tty] = 0
            }
            if let offset {
                latch.previousFDOffsets[tty] = offset
            }
            if let ioDate {
                latch.previousIODates[tty] = ioDate
            }
            if let size {
                latch.previousWinsizes[tty] = size
            }
        }
    }

    private static func didChange<T: Equatable>(_ current: T?, previous: T?) -> Bool {
        guard let current, let previous else { return false }
        return current != previous
    }

    private static func focusedSurfaceTTY(
        bundleIdentifier: String?,
        terminalPID: Int32?,
        application: NSRunningApplication?,
        snapshot: TerminalCLIProcessSnapshot
    ) -> String? {
        guard let terminalPID else { return nil }
        let bundle = (bundleIdentifier ?? "").lowercased()
        guard bundle.contains("kitty") else { return nil }
        return kittyFocusedTTY(
            terminalPID: terminalPID,
            application: application,
            snapshot: snapshot
        )
    }

    private static func kittyFocusedTTY(
        terminalPID: Int32,
        application: NSRunningApplication?,
        snapshot: TerminalCLIProcessSnapshot
    ) -> String? {
        guard let listenOn = environmentValue(forKey: "KITTY_LISTEN_ON", pid: terminalPID),
              !listenOn.isEmpty else {
            return nil
        }
        guard let executable = application?.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            return nil
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["@", "--to", listenOn, "ls"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return TerminalFocusHint.focusedKittyTTY(
                lsJSON: data,
                snapshot: snapshot,
                terminalPID: terminalPID
            )
        } catch {
            return nil
        }
    }

    private static func environmentValue(forKey key: String, pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<Int32>.alignment
        )
        defer { buffer.deallocate() }
        var got = size
        guard sysctl(&mib, 3, buffer, &got, nil, 0) == 0, got > MemoryLayout<Int32>.size else {
            return nil
        }
        return parseProcArgs2Env(buffer: buffer, length: got, key: key)
    }

    private static func parseProcArgs2Env(
        buffer: UnsafeRawPointer,
        length: Int,
        key: String
    ) -> String? {
        let argc = buffer.load(as: Int32.self)
        guard argc >= 0, argc < 4096 else { return nil }
        var offset = MemoryLayout<Int32>.size
        guard let pathEnd = nulOffset(buffer, length: length, from: offset) else { return nil }
        offset = pathEnd + 1
        while offset < length, buffer.load(fromByteOffset: offset, as: CChar.self) == 0 {
            offset += 1
        }
        for _ in 0..<argc {
            guard let end = nulOffset(buffer, length: length, from: offset) else { return nil }
            offset = end + 1
        }
        let prefix = key + "="
        while offset < length {
            if buffer.load(fromByteOffset: offset, as: CChar.self) == 0 { break }
            guard let end = nulOffset(buffer, length: length, from: offset) else { return nil }
            let bytes = buffer.advanced(by: offset).assumingMemoryBound(to: CChar.self)
            let line = String(cString: bytes)
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
            offset = end + 1
        }
        return nil
    }

    private static func nulOffset(_ buffer: UnsafeRawPointer, length: Int, from: Int) -> Int? {
        var index = from
        while index < length {
            if buffer.load(fromByteOffset: index, as: CChar.self) == 0 {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func ptyFDOffsets(terminalPID: Int32) -> [String: Int64] {
        var size = proc_pidinfo(terminalPID, procPIDListFDs, 0, nil, 0)
        guard size > 0 else { return [:] }
        size = max(size, Int32(procFDInfoSize))
        let list = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { list.deallocate() }
        let written = proc_pidinfo(terminalPID, procPIDListFDs, 0, list, size)
        guard written >= procFDInfoSize else { return [:] }

        let count = Int(written) / procFDInfoSize
        var result: [String: Int64] = [:]
        for index in 0..<count {
            let fd = list.load(fromByteOffset: index * procFDInfoSize, as: Int32.self)
            let type = list.load(fromByteOffset: index * procFDInfoSize + 4, as: UInt32.self)
            guard type == procFDTypeVNode else { continue }
            guard let parsed = vnodePTY(terminalPID: terminalPID, fd: fd) else { continue }
            result[parsed.tty] = max(result[parsed.tty] ?? .min, parsed.offset)
        }
        return result
    }

    private static func vnodePTY(terminalPID: Int32, fd: Int32) -> (tty: String, offset: Int64)? {
        var info = [UInt8](repeating: 0, count: vnodeFDInfoWithPathSize)
        let got = info.withUnsafeMutableBytes { buffer in
            proc_pidfdinfo(
                terminalPID,
                fd,
                procPIDFDVNodePathInfo,
                buffer.baseAddress,
                Int32(vnodeFDInfoWithPathSize)
            )
        }
        guard got >= pathOffset + 1 else { return nil }
        let offset = info.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: fileOffsetOffset, as: Int64.self)
        }
        let rdev = info.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: rdevOffset, as: UInt32.self)
        }
        let path = info.withUnsafeBytes { buffer -> String? in
            guard let base = buffer.baseAddress?.advanced(by: pathOffset) else {
                return nil
            }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        guard let path, let tty = TerminalPTYFDActivity.ttyName(path: path, rdev: rdev) else {
            return nil
        }
        return (tty, offset)
    }

    private static func ensureTerminalAppleEventPermission() -> TerminalAppleEventPermission {
        scriptCacheLock.lock()
        let cached = terminalAppleEventPermission
        let alreadyAsked = didAskTerminalAppleEventPermission
        scriptCacheLock.unlock()

        if cached == .allowed {
            return .allowed
        }

        let askUser = cached == .unknown && !alreadyAsked
        let status = onMainSync {
            determinePermissionToAutomateTerminal(askUserIfNeeded: askUser)
        }
        let permission = permission(fromAppleEventStatus: status)
        scriptCacheLock.lock()
        if permission != .unknown {
            terminalAppleEventPermission = permission
            if askUser {
                didAskTerminalAppleEventPermission = true
            }
        }
        scriptCacheLock.unlock()
        return permission == .unknown ? cached : permission
    }

    private static func cacheTerminalAppleEventPermission(_ permission: TerminalAppleEventPermission) {
        scriptCacheLock.lock()
        terminalAppleEventPermission = permission
        if permission != .unknown {
            didAskTerminalAppleEventPermission = true
        }
        scriptCacheLock.unlock()
    }

    private static func determinePermissionToAutomateTerminal(askUserIfNeeded: Bool) -> OSStatus {
        var address = AEAddressDesc()
        let bundleID = "com.apple.Terminal"
        let created = bundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, bundleID.utf8.count, &address)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&address) }
        return AEDeterminePermissionToAutomateTarget(
            &address,
            typeWildCard,
            typeWildCard,
            askUserIfNeeded
        )
    }

    private static func onMainSync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        var result: T!
        DispatchQueue.main.sync {
            result = work()
        }
        return result
    }

    private static func runCachedAppleScript(
        bundleIdentifier: String?,
        applicationPath: String?
    ) -> String? {
        let bundle = (bundleIdentifier ?? "").lowercased()
        let path = applicationPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let started = Date()
        scriptCacheLock.lock()
        if appleScriptExecuting {
            scriptCacheLock.unlock()
            recordAppleScriptStatus(.skippedExecuting, duration: 0)
            return nil
        }
        if let skipUntil = appleScriptSkipUntil, Date() < skipUntil {
            scriptCacheLock.unlock()
            recordAppleScriptStatus(.skippedBackoff, duration: 0)
            return nil
        }
        appleScriptExecuting = true
        scriptCacheLock.unlock()

        let finishWithoutScript: (TerminalAppleScriptStatus, String?) -> String? = { status, raw in
            scriptCacheLock.lock()
            appleScriptExecuting = false
            scriptCacheLock.unlock()
            recordAppleScriptStatus(
                status,
                duration: Date().timeIntervalSince(started),
                raw: raw
            )
            return raw
        }

        if bundle == "com.apple.terminal" {
            let permission = ensureTerminalAppleEventPermission()
            if permission == .denied {
                markAppleScriptFailure()
                return finishWithoutScript(.failure, "ERR\n-1743\nnot authorized")
            }
            if permission != .allowed {
                markAppleScriptFailure()
                return finishWithoutScript(.failure, "ERR\npending\nTerminal Apple Events permission pending")
            }
        }
        if isGhosttyBundle(bundle), path.isEmpty {
            return finishWithoutScript(.failure, "ERR\nno_app_path\n")
        }
        guard let source = appleScriptSource(
            bundleIdentifier: bundle,
            applicationPath: path.isEmpty ? nil : path
        ) else {
            return finishWithoutScript(.failure, nil)
        }

        let cacheKey = "\(bundle)|\(path)"
        let compiled = compiledAppleScript(cacheKey: cacheKey, source: source)
        if let compileError = compiled.errorRaw {
            markAppleScriptFailure()
            return finishWithoutScript(.failure, compileError)
        }
        guard let script = compiled.script else {
            markAppleScriptFailure()
            return finishWithoutScript(.failure, nil)
        }

        let box = AppleScriptRunBox()
        let finished = DispatchSemaphore(value: 0)
        appleScriptQueue.async {
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            box.error = error
            box.stringValue = result.stringValue
            scriptCacheLock.lock()
            appleScriptExecuting = false
            scriptCacheLock.unlock()
            finished.signal()
        }

        if finished.wait(timeout: .now() + appleScriptTimeout) == .timedOut {
            markAppleScriptFailure()
            recordAppleScriptStatus(.timeout, duration: Date().timeIntervalSince(started))
            return nil
        }

        let duration = Date().timeIntervalSince(started)
        if let error = box.error {
            markAppleScriptFailure()
            let raw = appleScriptErrorPayload(from: error, fallback: box.stringValue)
            if bundle == "com.apple.terminal", appleScriptErrorCode(raw) == "-1743" {
                cacheTerminalAppleEventPermission(.denied)
            }
            recordAppleScriptStatus(.failure, duration: duration, raw: raw)
            return raw
        }
        let value = box.stringValue
        if isAppleScriptErrorPayload(value) {
            let code = appleScriptErrorCode(value) ?? ""
            if bundle == "com.apple.terminal", code == "-1743" {
                cacheTerminalAppleEventPermission(.denied)
            }
            if Int(code) != nil {
                markAppleScriptFailure()
            }
            recordAppleScriptStatus(.failure, duration: duration, raw: value)
            return value
        }
        if isAppleScriptPayloadEmpty(value) {
            recordAppleScriptStatus(.empty, duration: duration, raw: value)
            return value
        }
        recordAppleScriptStatus(.value, duration: duration, raw: value)
        return value
    }

    static func waitWithTimeout<T>(
        _ timeout: TimeInterval,
        execute: @escaping () -> T
    ) -> T? {
        let box = TimeoutBox<T>()
        let finished = DispatchSemaphore(value: 0)
        appleScriptQueue.async {
            box.value = execute()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            return nil
        }
        return box.value
    }

    static func compactIdentityTitle(_ title: String?, limit: Int = 32) -> String {
        guard let title else { return "-" }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        var value = trimmed
        if value.hasPrefix("/") {
            if let separator = value.range(of: " - ", options: .backwards) {
                value = String(value[separator.upperBound...])
            } else {
                value = (value as NSString).lastPathComponent
            }
        }
        if value.count > limit {
            return "…" + String(value.suffix(limit - 1))
        }
        return value
    }

    static func compactIdentityRaw(_ raw: String?, limit: Int = 80) -> String {
        guard let raw else { return "-" }
        var value = stripHomePaths(raw)
        if !isAppleScriptErrorPayload(raw), value.hasPrefix("/") {
            if let separator = value.range(of: " - ", options: .backwards) {
                value = String(value[separator.upperBound...])
            } else if let last = value.split(separator: "/").last {
                value = String(last)
            }
        }
        value = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        if value.isEmpty { return "-" }
        if value.count > limit {
            return String(value.prefix(limit - 1)) + "…"
        }
        return value
    }

    private static func compiledAppleScript(
        cacheKey: String,
        source: String
    ) -> (script: NSAppleScript?, errorRaw: String?) {
        scriptCacheLock.lock()
        if let cached = compiledAppleScripts[cacheKey] {
            scriptCacheLock.unlock()
            return (cached, nil)
        }
        scriptCacheLock.unlock()

        guard let script = NSAppleScript(source: source) else {
            return (nil, "ERR\ncompile\n")
        }
        var error: NSDictionary?
        if !script.compileAndReturnError(&error) {
            return (nil, appleScriptErrorPayload(from: error, fallback: nil))
        }
        scriptCacheLock.lock()
        compiledAppleScripts[cacheKey] = script
        scriptCacheLock.unlock()
        return (script, nil)
    }

    private static func appleScriptErrorPayload(
        from error: NSDictionary?,
        fallback: String?
    ) -> String {
        if let fallback, isAppleScriptErrorPayload(fallback) {
            return fallback
        }
        let number = (error?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            ?? (error?["NSAppleScriptErrorNumber"] as? Int)
        let message = (error?["NSAppleScriptErrorMessage"] as? String) ?? fallback ?? ""
        let code = number.map(String.init) ?? "failure"
        let truncated = truncateAppleScriptError(stripHomePaths(message))
        return "ERR\n\(code)\n\(truncated)"
    }

    private static func stripHomePaths(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty else { return value }
        return value.replacingOccurrences(of: home, with: "~")
    }

    private static func truncateAppleScriptError(_ value: String, limit: Int = 80) -> String {
        if value.count <= limit { return value }
        return String(value.prefix(limit - 1)) + "…"
    }

    private static func markAppleScriptFailure() {
        scriptCacheLock.lock()
        appleScriptSkipUntil = Date().addingTimeInterval(appleScriptBackoffInterval)
        scriptCacheLock.unlock()
    }

    private static func recordAppleScriptStatus(
        _ status: TerminalAppleScriptStatus,
        duration: TimeInterval,
        raw: String? = nil
    ) {
        scriptCacheLock.lock()
        lastAppleScriptStatus = status
        lastAppleScriptDuration = duration
        lastAppleScriptRaw = raw
        scriptCacheLock.unlock()
    }

    private static func logIdentityTick(
        signal: TerminalSelectedTabSignal,
        focusedTTY: String?,
        latchTTY: String?,
        grokTTYs: Set<String>,
        claudeTTYs: Set<String>,
        duration: TimeInterval
    ) {
        scriptCacheLock.lock()
        let status = lastAppleScriptStatus
        let appleScriptMS = Int((lastAppleScriptDuration * 1000).rounded())
        let raw = lastAppleScriptRaw
        scriptCacheLock.unlock()
        let classified = classifiedClient(
            tty: focusedTTY,
            grokTTYs: grokTTYs,
            claudeTTYs: claudeTTYs
        )
        let compactRaw = compactIdentityRaw(raw)
        let err = appleScriptErrorCode(raw) ?? "-"
        let signature = [
            signal.tty ?? "-",
            signal.pid.map(String.init) ?? "-",
            focusedTTY ?? "-",
            classified,
            status.rawValue,
            err,
            compactRaw
        ].joined(separator: "|")
        let important = status == .timeout
            || status == .failure
            || status == .skippedExecuting
            || status == .empty
            || classified == "-"
        identityLogLock.lock()
        let now = Date()
        let changed = signature != lastIdentityLogSignature
        let due = now.timeIntervalSince(lastIdentityLogAt) >= 1
        guard important || changed || due else {
            identityLogLock.unlock()
            return
        }
        lastIdentityLogSignature = signature
        lastIdentityLogAt = now
        identityLogLock.unlock()

        SwitchLog.write(
            "identity tick; selected_tty=\(signal.tty ?? "-"); pid=\(signal.pid.map(String.init) ?? "-"); title=\(compactIdentityTitle(signal.title)); classified=\(classified); latch=\(latchTTY ?? "-"); applescript=\(status.rawValue); err=\(err); ms=\(appleScriptMS); total_ms=\(Int((duration * 1000).rounded())); raw=\(compactRaw)",
            level: .debug,
            category: "identity"
        )
    }

    private static func classifiedClient(
        tty: String?,
        grokTTYs: Set<String>,
        claudeTTYs: Set<String>
    ) -> String {
        guard let tty = uniquelyClassifiedTTY(
            tty,
            grokTTYs: grokTTYs,
            claudeTTYs: claudeTTYs
        ) else {
            return "-"
        }
        return grokTTYs.contains(tty) ? "grok" : "claude"
    }
}

private final class AppleScriptRunBox {
    var stringValue: String?
    var error: NSDictionary?
}

private final class TimeoutBox<T> {
    var value: T?
}
