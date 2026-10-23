import Darwin
import Foundation

/// Looks up when a Claude Code session's process started, from Claude Code's own session
/// registry (`~/.claude/sessions/<pid>.json`). Used only on the first payload of a session.
protocol ClaudeSessionStartLookup {
    func startedAt(sessionID: String) -> Date?
}

/// Reads the small per-process registry Claude Code keeps; it never touches transcripts.
final class ClaudeSessionRegistry: ClaudeSessionStartLookup {
    private let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions"),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func startedAt(sessionID: String) -> Date? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
        var latest: Date?
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  (attributes[.size] as? NSNumber)?.intValue ?? .max <= 16_384,
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["sessionId"] as? String == sessionID,
                  let milliseconds = (object["startedAt"] as? NSNumber)?.doubleValue else { continue }
            // A resumed session is registered again by its new process; the newest start wins.
            let date = Date(timeIntervalSince1970: milliseconds / 1_000)
            latest = max(latest ?? date, date)
        }
        return latest
    }
}

/// Receives the compact payload emitted by the BalanceBar statusLine wrapper.
///
/// statusLine JSON carries no account, so attribution is a conservative association:
/// - a session started before an observed account switch is never accepted;
/// - a session started while the current account was already active is accepted;
/// - any other session (started before BalanceBar, or with an unknown start) is accepted
///   only when both windows' reset times match the latest official reading to the second.
/// Identical values never extend freshness, because statusLine re-runs replay cached data.
final class ClaudeStatusLineSource: QuotaSource, RealtimeSourceFreshnessProviding, ManualRefreshFreePathChecking {
    static let identifier = "claude-statusline"
    static let maximumPayloadBytes = 4_096
    var sourceID: String { Self.identifier }
    var lastTrustedRealtimeObservationAt: Date? { tracker.lastTrustedRealtimeObservationAt }

    struct WindowValue: Equatable {
        let used: Double
        let reset: Date?
    }

    private enum Attribution {
        /// Started while the current account was already active.
        case verified
        /// Owner unknown; accepted only with a full reset-time fingerprint match.
        case fingerprintOnly
        /// Started before an observed account switch.
        case rejected
    }

    private struct SessionState {
        let epoch: AccountEpoch
        let attribution: Attribution
        var lastValues: [QuotaWindowKind: WindowValue]
        var hasBaseline: Bool
        var lastUsedAt: Date
    }

    private let socketURL: URL
    private let accountProvider: AccountIdentityProviding
    private let tracker: ClaudeRealtimeTracker
    private let sessionStarts: ClaudeSessionStartLookup
    private let now: () -> Date
    /// Merge state; never blocks on sockets.
    private let queue = DispatchQueue(label: "BalanceBar.ClaudeStatusLineSource", qos: .utility)
    /// Accepts and reads clients; bounded by a per-client deadline.
    private let ioQueue = DispatchQueue(label: "BalanceBar.ClaudeStatusLineSource.IO", qos: .utility)
    private var handler: ((QuotaObservation) -> Void)?
    /// Connections taken off the listener, valid or not; touched only on `ioQueue`.
    private var handledConnections = 0
    private var listener: DispatchSourceRead?
    private var listenerStartedAt: Date?
    private var sessions: [String: SessionState] = [:]
    private var gradeAResets: [QuotaWindowKind: Date?] = [:]
    private var identityConflict = false
    private var observedEpoch: AccountEpoch?
    /// When the current account became active, if a switch was seen while running.
    private var accountActiveSince: Date?

    init(
        accountProvider: AccountIdentityProviding,
        tracker: ClaudeRealtimeTracker,
        socketURL: URL = ClaudeStatusLineSource.defaultSocketURL,
        sessionStarts: ClaudeSessionStartLookup = ClaudeSessionRegistry(),
        now: @escaping () -> Date = Date.init
    ) {
        self.accountProvider = accountProvider
        self.tracker = tracker
        self.socketURL = socketURL
        self.sessionStarts = sessionStarts
        self.now = now
    }

    static var defaultSocketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BalanceBar/run/sl.sock")
    }

    func start(receiving handler: @escaping (QuotaObservation) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            self.handler = handler
            guard let fd = makeListener() else { return }
            listenerStartedAt = now()
            // The event and cancel handlers share `ioQueue`, so the descriptor is closed only
            // after any in-progress accept loop ends, and only by the cancel handler.
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
            source.setEventHandler { [weak self] in self?.acceptClients(listenerFD: fd) }
            source.setCancelHandler { close(fd) }
            listener = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    /// Number of connections read so far. Intended for tests.
    var handledConnectionCount: Int { ioQueue.sync { handledConnections } }

    /// Blocks until queued merge work has run. Intended for tests.
    func waitUntilIdle() {
        ioQueue.sync {}
        queue.sync {}
    }

    func checkFreePath(within window: TimeInterval, completion: @escaping (Bool) -> Void) {
        tracker.checkFreePath(within: window, completion: completion)
    }

    func setGradeAResets(_ resets: [QuotaWindowKind: Date?]) {
        queue.async { [self] in
            gradeAResets = resets
            recomputeConflict()
        }
    }

    /// Records an account switch seen by the pipeline; earlier sessions are no longer trusted.
    func accountDidChange(epoch: AccountEpoch) {
        queue.async { [self] in noteEpoch(epoch, switchedAt: now()) }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        listenerStartedAt = nil
        unlink(socketURL.path)
        handler = nil
        sessions.removeAll()
        gradeAResets.removeAll()
        identityConflict = false
        tracker.markIdentityConflict(false)
    }

    private func makeListener() -> Int32? {
        let directory = socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        unlink(socketURL.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { close(fd); return nil }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); unlink(socketURL.path); return nil }
        return fd
    }

    // MARK: - IO queue

    private func acceptClients(listenerFD: Int32) {
        while true {
            let client = Darwin.accept(listenerFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // EAGAIN/EWOULDBLOCK: drained; any other error waits for the next event.
            }
            let data = Self.readClient(client)
            if let data { queue.async { [weak self] in self?.accept(data: data) } }
            handledConnections += 1
        }
    }

    /// Reads one bounded message; the whole read is limited to 100 ms so a stuck peer cannot
    /// hold the IO queue.
    static func readClient(_ fd: Int32) -> Data? {
        defer { close(fd) }
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        guard getpeereid(fd, &effectiveUID, &effectiveGID) == 0, effectiveUID == geteuid() else { return nil }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > maximumPayloadBytes { return nil }
                continue
            }
            if count == 0 { return data.isEmpty ? nil : data }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { return nil }
            let remaining = Int64(deadline) - Int64(DispatchTime.now().uptimeNanoseconds)
            guard remaining > 0 else { return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&poller, 1, Int32(max(1, remaining / 1_000_000)))
        }
    }

    // MARK: - Merge queue

    private func noteEpoch(_ epoch: AccountEpoch, switchedAt date: Date) {
        guard let observedEpoch else {
            self.observedEpoch = epoch
            return
        }
        guard epoch != observedEpoch else { return }
        self.observedEpoch = epoch
        accountActiveSince = date
        sessions.removeAll()
        identityConflict = false
        tracker.markIdentityConflict(false)
    }

    private func accept(data: Data) {
        guard handler != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] as? Int == 1,
              let sessionID = object["sessionID"] as? String, !sessionID.isEmpty, sessionID.count <= 128,
              let identity = accountProvider.accountIdentity else { return }
        let epoch = accountProvider.accountEpoch
        let receivedAt = now()
        noteEpoch(epoch, switchedAt: receivedAt)
        let windows = Self.parseWindows(object, at: receivedAt)
        guard !windows.isEmpty else { return }

        if sessions[sessionID] == nil {
            if sessions.count >= 32, let oldest = sessions.min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt })?.key {
                sessions.removeValue(forKey: oldest)
            }
            let started = sessionStarts.startedAt(sessionID: sessionID)
            let attribution = attribute(started: started)
            // A session that started after the listener did cannot be replaying data from
            // before BalanceBar was listening, so its first payload is already evidence.
            let firstIsEvidence = attribution == .verified
                && started.map { started in listenerStartedAt.map { started >= $0 } ?? false } ?? false
            sessions[sessionID] = SessionState(
                epoch: epoch, attribution: attribution, lastValues: [:], hasBaseline: !firstIsEvidence,
                lastUsedAt: receivedAt)
            if !firstIsEvidence {
                sessions[sessionID]?.lastValues = windows
                return
            }
        }
        guard var session = sessions[sessionID] else { return }
        session.lastUsedAt = receivedAt
        defer { sessions[sessionID] = session }
        guard session.epoch == epoch, session.attribution != .rejected else { return }
        // Only changed values are new evidence; a re-run with the same numbers is a replay.
        if session.hasBaseline, windows.allSatisfy({ session.lastValues[$0.key] == $0.value }) { return }
        for (window, value) in windows {
            if let previous = session.lastValues[window], value.reset == previous.reset, value.used < previous.used {
                return // Usage never decreases within a cycle: an older snapshot.
            }
        }
        session.lastValues.merge(windows) { _, new in new }
        session.hasBaseline = true
        sessions[sessionID] = session // the conflict check reads every session, this one included
        recomputeConflict()
        guard !identityConflict else { return }
        if session.attribution == .fingerprintOnly, !matchesGradeAFingerprint(windows) { return }
        emit(windows: windows, identity: identity, epoch: epoch, receivedAt: receivedAt)
    }

    private func attribute(started: Date?) -> Attribution {
        if let accountActiveSince {
            guard let started, started >= accountActiveSince else { return .rejected }
            return .verified
        }
        // No switch seen while running: a session started after BalanceBar began listening
        // runs under the account BalanceBar loaded at that time.
        if let started, let listenerStartedAt, started >= listenerStartedAt { return .verified }
        return .fingerprintOnly
    }

    /// Both standard windows present, each matching the official reset time to the second.
    private func matchesGradeAFingerprint(_ windows: [QuotaWindowKind: WindowValue]) -> Bool {
        for kind in [QuotaWindowKind.fiveHour, .sevenDay] {
            guard let value = windows[kind], let reset = value.reset,
                  let expectedEntry = gradeAResets[kind], let expected = expectedEntry,
                  reset.timeIntervalSince1970.rounded() == expected.timeIntervalSince1970.rounded() else { return false }
        }
        return true
    }

    static func parseWindows(_ object: [String: Any], at date: Date) -> [QuotaWindowKind: WindowValue] {
        var result: [QuotaWindowKind: WindowValue] = [:]
        for (key, kind, duration) in [("fiveHour", QuotaWindowKind.fiveHour, 5 * 3_600.0), ("sevenDay", .sevenDay, 7 * 86_400.0)] {
            guard let raw = object[key] as? [String: Any],
                  let number = raw["usedPercentage"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let used = number.doubleValue
            guard used.isFinite, (0...100).contains(used) else { continue }
            var reset: Date?
            if let rawReset = raw["resetsAt"] as? NSNumber, CFGetTypeID(rawReset) != CFBooleanGetTypeID() {
                let seconds = rawReset.doubleValue
                guard seconds.isFinite else { continue }
                let candidate = Date(timeIntervalSince1970: seconds)
                // Claude Code drops a window once it resets, so a past reset is malformed.
                guard candidate > date.addingTimeInterval(-60),
                      candidate <= date.addingTimeInterval(duration + 3_600) else { continue }
                reset = candidate
            }
            result[kind] = WindowValue(used: used, reset: reset)
        }
        return result
    }

    private func emit(windows: [QuotaWindowKind: WindowValue], identity: AccountIdentity, epoch: AccountEpoch, receivedAt: Date) {
        for (window, value) in windows {
            guard let observation = QuotaObservation(window: window, usedPercentage: value.used,
                    resetsAt: value.reset, observedAt: nil, receivedAt: receivedAt,
                    source: Self.identifier, trust: .b, accountID: identity.stableID, epoch: epoch) else { continue }
            handler?(observation)
        }
    }

    /// Two attributable sessions disagreeing on the official reset time means two identities
    /// are reporting at once; native data stops until the next official reading.
    private func recomputeConflict() {
        guard !gradeAResets.isEmpty else { return }
        let conflict = gradeAResets.contains { window, expected in
            let values = sessions.values.filter { $0.attribution != .rejected }
                .compactMap { $0.lastValues[window]?.reset?.timeIntervalSince1970.rounded() }
            guard let expected = expected?.timeIntervalSince1970.rounded(), !values.isEmpty else { return false }
            return values.contains(expected) && values.contains(where: { $0 != expected })
        }
        identityConflict = conflict
        tracker.markIdentityConflict(conflict)
    }
}
