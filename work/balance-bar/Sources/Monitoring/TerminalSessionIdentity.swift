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
        guard let source = appleScriptSource(bundleIdentifier: application?.bundleIdentifier) else {
            return nil
        }
        return TerminalCLIProcessRecord.normalizeTTY(runAppleScript(source))
    }

    static func resolve(
        application: NSRunningApplication?,
        snapshot: TerminalCLIProcessSnapshot
    ) -> String? {
        let terminalPID = application?.processIdentifier
        let appleScriptTTY = selectedTTY(application: application)
        let belonging = terminalPID.map {
            snapshot.cliProcesses(underTerminalPID: $0).filter { $0.tty != nil }
        } ?? []
        let candidateTTYs = belonging.compactMap(\.tty)
        let offsets = terminalPID.map { ptyFDOffsets(terminalPID: $0) } ?? [:]
        var winsizes: [String: TerminalTTYWinsize] = [:]
        for tty in Set(candidateTTYs) {
            if let size = winsize(forTTY: tty) {
                winsizes[tty] = size
            }
        }
        let needsSurfaceLookup = appleScriptTTY == nil && candidateTTYs.count > 1
        let ipcTTY = needsSurfaceLookup
            ? focusedSurfaceTTY(
                bundleIdentifier: application?.bundleIdentifier,
                terminalPID: terminalPID,
                application: application,
                snapshot: snapshot
            )
            : nil
        let title = needsSurfaceLookup ? terminalPID.flatMap(frontWindowTitle(ownerPID:)) : nil

        latchLock.lock()
        defer { latchLock.unlock() }
        return resolve(
            bundleIdentifier: application?.bundleIdentifier,
            terminalPID: terminalPID,
            snapshot: snapshot,
            appleScriptTTY: appleScriptTTY,
            ttyIODate: ioDate(forTTY:),
            ttyFDOffset: { offsets[$0] },
            ttyWinsize: { winsizes[$0] },
            ipcTTY: ipcTTY,
            windowTitle: title,
            latch: &focusLatch
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

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}
