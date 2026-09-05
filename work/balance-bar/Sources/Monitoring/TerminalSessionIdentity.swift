import AppKit
import CoreGraphics
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

enum TerminalFocusHint {
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

    enum AppleScriptQuery: String {
        case tty
        case pid
    }

    static func appleScriptSource(bundleIdentifier: String?) -> String? {
        appleScriptSource(bundleIdentifier: bundleIdentifier, query: .tty)
    }

    static func appleScriptSource(
        bundleIdentifier: String?,
        query: AppleScriptQuery
    ) -> String? {
        let bundle = (bundleIdentifier ?? "").lowercased()
        switch bundle {
        case "com.apple.terminal":
            guard query == .tty else { return nil }
            return """
            tell application id "com.apple.Terminal"
                if not (exists front window) then return ""
                return tty of selected tab of front window
            end tell
            """
        case "com.googlecode.iterm2":
            guard query == .tty else { return nil }
            return """
            tell application id "com.googlecode.iterm2"
                try
                    return tty of current session of current window
                on error
                    return ""
                end try
            end tell
            """
        case "com.mitchellh.ghostty":
            return ghosttyAppleScriptSource(query: query)
        default:
            if bundle.hasSuffix(".ghostty") {
                return ghosttyAppleScriptSource(query: query)
            }
            return nil
        }
    }

    private static func ghosttyAppleScriptSource(query: AppleScriptQuery) -> String {
        switch query {
        case .tty:
            return """
            tell application id "com.mitchellh.ghostty"
                if not (exists front window) then return ""
                try
                    return tty of focused terminal of selected tab of front window
                on error
                    return ""
                end try
            end tell
            """
        case .pid:
            return """
            tell application id "com.mitchellh.ghostty"
                if not (exists front window) then return ""
                try
                    return pid of focused terminal of selected tab of front window as string
                on error
                    return ""
                end try
            end tell
            """
        }
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
        selectedTabSignal(bundleIdentifier: application?.bundleIdentifier).tty
    }

    static func selectedTabSignal(bundleIdentifier: String?) -> (tty: String?, pid: Int32?) {
        guard appleScriptSource(bundleIdentifier: bundleIdentifier, query: .tty) != nil else {
            return (nil, nil)
        }
        if let tty = TerminalCLIProcessRecord.normalizeTTY(
            runCachedAppleScript(bundleIdentifier: bundleIdentifier, query: .tty)
        ) {
            return (tty, nil)
        }
        guard appleScriptSource(bundleIdentifier: bundleIdentifier, query: .pid) != nil else {
            return (nil, nil)
        }
        guard let raw = runCachedAppleScript(bundleIdentifier: bundleIdentifier, query: .pid) else {
            return (nil, nil)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 0 else {
            return (nil, nil)
        }
        return (nil, pid)
    }

    static func uniquelyClassifiedTTY(
        _ rawTTY: String?,
        grokTTYs: Set<String>,
        claudeTTYs: Set<String>
    ) -> String? {
        guard let tty = TerminalCLIProcessRecord.normalizeTTY(rawTTY) else { return nil }
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
        let bundle = application?.bundleIdentifier
        let signal = appleScriptSource(bundleIdentifier: bundle) == nil
            ? (tty: nil, pid: nil as Int32?)
            : selectedTabSignal(bundleIdentifier: bundle)
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
            windowTitle: {
                guard let application else { return nil }
                return frontWindowTitle(ownerPID: application.processIdentifier)
            },
            latch: &latch
        )
        latchLock.lock()
        focusLatch = latch
        latchLock.unlock()
        return (focused.tty, snapshot)
    }

    static func resolveFocus(
        bundleIdentifier: String?,
        terminalPID: Int32?,
        grokTTYs: Set<String>,
        claudeTTYs: Set<String>,
        appleScriptTTY: String?,
        appleScriptPID: Int32?,
        loadSnapshot: @escaping () -> TerminalCLIProcessSnapshot?,
        ttyIODate: @escaping (String) -> Date?,
        ttyFDOffsets: () -> [String: Int64],
        ttyWinsize: @escaping (String) -> TerminalTTYWinsize?,
        ipcTTY: () -> String?,
        windowTitle: () -> String?,
        latch: inout TerminalTTYFocusLatch
    ) -> (tty: String?, loadedSnapshot: Bool, probedSurface: Bool) {
        if let selected = TerminalCLIProcessRecord.normalizeTTY(appleScriptTTY) {
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

        guard let snap = snapshotValue() else {
            if latch.terminalPID != terminalPID {
                latch = TerminalTTYFocusLatch(terminalPID: terminalPID)
            }
            return (nil, loadedSnapshot, false)
        }

        let offsets = ttyFDOffsets()
        var winsizes: [String: TerminalTTYWinsize] = [:]
        let belonging = terminalPID.map {
            snap.cliProcesses(underTerminalPID: $0).filter { $0.tty != nil }
        } ?? []
        let candidateTTYs = belonging.compactMap(\.tty)
        for tty in Set(candidateTTYs) {
            if let size = ttyWinsize(tty) {
                winsizes[tty] = size
            }
        }
        let needsSurfaceLookup = appleScriptTTY == nil && candidateTTYs.count > 1
        let ipc = needsSurfaceLookup ? ipcTTY() : nil
        let title = needsSurfaceLookup ? windowTitle() : nil
        let tty = resolve(
            bundleIdentifier: bundleIdentifier,
            terminalPID: terminalPID,
            snapshot: snap,
            appleScriptTTY: appleScriptTTY,
            ttyIODate: ttyIODate,
            ttyFDOffset: { offsets[$0] },
            ttyWinsize: { winsizes[$0] },
            ipcTTY: ipc,
            windowTitle: title,
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

    private static func frontWindowTitle(ownerPID: Int32) -> String? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        for window in list {
            guard intValue(window[kCGWindowOwnerPID as String]) == Int(ownerPID) else {
                continue
            }
            let layer = intValue(window[kCGWindowLayer as String]) ?? 0
            guard layer == 0 else { continue }
            if let title = window[kCGWindowName as String] as? String, !title.isEmpty {
                return title
            }
            return nil
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int32 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
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

    private static func runCachedAppleScript(
        bundleIdentifier: String?,
        query: AppleScriptQuery
    ) -> String? {
        let bundle = (bundleIdentifier ?? "").lowercased()
        scriptCacheLock.lock()
        if let skipUntil = appleScriptSkipUntil, Date() < skipUntil {
            scriptCacheLock.unlock()
            return nil
        }
        scriptCacheLock.unlock()

        guard let script = compiledAppleScript(bundleIdentifier: bundle, query: query) else {
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil {
            markAppleScriptFailure()
            return nil
        }
        let value = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    private static func compiledAppleScript(
        bundleIdentifier: String,
        query: AppleScriptQuery
    ) -> NSAppleScript? {
        let key = bundleIdentifier + "|" + query.rawValue
        scriptCacheLock.lock()
        if let cached = compiledAppleScripts[key] {
            scriptCacheLock.unlock()
            return cached
        }
        scriptCacheLock.unlock()

        guard let source = appleScriptSource(bundleIdentifier: bundleIdentifier, query: query) else {
            return nil
        }
        guard let script = NSAppleScript(source: source) else {
            markAppleScriptFailure()
            return nil
        }
        var error: NSDictionary?
        if !script.compileAndReturnError(&error) {
            markAppleScriptFailure()
            return nil
        }
        scriptCacheLock.lock()
        compiledAppleScripts[key] = script
        scriptCacheLock.unlock()
        return script
    }

    private static func markAppleScriptFailure() {
        scriptCacheLock.lock()
        appleScriptSkipUntil = Date().addingTimeInterval(appleScriptBackoffInterval)
        scriptCacheLock.unlock()
    }
}
