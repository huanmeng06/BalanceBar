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

    /// Tab selection advances the terminal's master pty offset even when the
    /// slave `/dev/ttys*` times stay frozen until the TUI receives input.
    static func updatedDates(
        offsets: [String: Int64],
        previousOffsets: [String: Int64],
        previousDates: [String: Date],
        now: Date
    ) -> (offsets: [String: Int64], dates: [String: Date]) {
        var nextOffsets: [String: Int64] = [:]
        var nextDates: [String: Date] = [:]
        for (tty, offset) in offsets {
            nextOffsets[tty] = offset
            if previousOffsets[tty] != offset {
                nextDates[tty] = now
            } else {
                nextDates[tty] = previousDates[tty] ?? now
            }
        }
        return (nextOffsets, nextDates)
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

    private static let fdCacheLock = NSLock()
    private static var previousFDOffsets: [String: Int64] = [:]
    private static var previousFDDates: [String: Date] = [:]

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
        ttyIODate: (String) -> Date?,
        ttyFDDate: (String) -> Date? = { _ in nil }
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
            isLessActive(
                lhsTTY: lhs.tty,
                rhsTTY: rhs.tty,
                ttyFDDate: ttyFDDate,
                ttyIODate: ttyIODate
            )
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
        let fdDates = application.map {
            ptyFDActivityDates(terminalPID: $0.processIdentifier)
        } ?? [:]
        return resolve(
            bundleIdentifier: application?.bundleIdentifier,
            terminalPID: application.map(\.processIdentifier),
            snapshot: snapshot,
            appleScriptTTY: selectedTTY(application: application),
            ttyIODate: ioDate(forTTY:),
            ttyFDDate: { fdDates[$0] }
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

    static func ptyFDActivityDates(terminalPID: Int32, now: Date = Date()) -> [String: Date] {
        let sampled = ptyFDOffsets(terminalPID: terminalPID)
        var keyed: [String: Int64] = [:]
        keyed.reserveCapacity(sampled.count)
        for (tty, offset) in sampled {
            keyed["\(terminalPID):\(tty)"] = offset
        }
        fdCacheLock.lock()
        let updated = TerminalPTYFDActivity.updatedDates(
            offsets: keyed,
            previousOffsets: previousFDOffsets,
            previousDates: previousFDDates,
            now: now
        )
        previousFDOffsets = updated.offsets
        previousFDDates = updated.dates
        fdCacheLock.unlock()

        let prefix = "\(terminalPID):"
        var dates: [String: Date] = [:]
        for (key, date) in updated.dates {
            guard key.hasPrefix(prefix) else { continue }
            dates[String(key.dropFirst(prefix.count))] = date
        }
        return dates
    }

    private static func isLessActive(
        lhsTTY: String?,
        rhsTTY: String?,
        ttyFDDate: (String) -> Date?,
        ttyIODate: (String) -> Date?
    ) -> Bool {
        let leftFD = lhsTTY.flatMap(ttyFDDate)
        let rightFD = rhsTTY.flatMap(ttyFDDate)
        switch (leftFD, rightFD) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return false
        case (nil, _?):
            return true
        default:
            break
        }
        let leftIO = lhsTTY.flatMap(ttyIODate) ?? .distantPast
        let rightIO = rhsTTY.flatMap(ttyIODate) ?? .distantPast
        return leftIO < rightIO
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
