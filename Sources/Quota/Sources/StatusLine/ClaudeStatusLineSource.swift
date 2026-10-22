import Darwin
import Foundation

/// Receives the compact payload emitted by the BalanceBar statusLine wrapper.
final class ClaudeStatusLineSource: QuotaSource, RealtimeSourceFreshnessProviding, ManualRefreshFreePathChecking {
    static let identifier = "claude-statusline"
    var sourceID: String { Self.identifier }
    var lastTrustedRealtimeObservationAt: Date? { tracker.lastTrustedRealtimeObservationAt }

    private struct WindowValue {
        let used: Double
        let reset: Date?
    }

    private struct SessionState {
        let firstSeenEpoch: AccountEpoch
        var lastSignature: String
        var lastValues: [QuotaWindowKind: WindowValue]
        var lastAcceptedAt: Date?
        var lastUsedAt: Date
    }

    private let socketURL: URL
    private let accountProvider: AccountIdentityProviding
    private let tracker: ClaudeRealtimeTracker
    private let now: () -> Date
    private let queue = DispatchQueue(label: "BalanceBar.ClaudeStatusLineSource", qos: .utility)
    private let stateLock = NSLock()
    private var handler: ((QuotaObservation) -> Void)?
    private var listener: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var sessions: [String: SessionState] = [:]
    private var gradeAResets: [QuotaWindowKind: Date?] = [:]
    private var identityConflict = false

    init(
        accountProvider: AccountIdentityProviding,
        tracker: ClaudeRealtimeTracker,
        socketURL: URL = ClaudeStatusLineSource.defaultSocketURL,
        now: @escaping () -> Date = Date.init
    ) {
        self.accountProvider = accountProvider
        self.tracker = tracker
        self.socketURL = socketURL
        self.now = now
    }

    static var defaultSocketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BalanceBar/run/sl.sock")
    }

    func start(receiving handler: @escaping (QuotaObservation) -> Void) {
        queue.async { [self] in
            stopLocked()
            self.handler = handler
            guard let fd = makeListener() else { return }
            socketFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients() }
            source.setCancelHandler { close(fd) }
            listener = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in stopLocked() }
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

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        unlink(socketURL.path)
        handler = nil
        sessions.removeAll()
        gradeAResets.removeAll()
        identityConflict = false
        tracker.markIdentityConflict(false)
    }

    private func makeListener() -> Int32? {
        do {
            try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketURL.deletingLastPathComponent().path)
        } catch { return nil }
        unlink(socketURL.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); unlink(socketURL.path); return nil }
        return fd
    }

    private func acceptClients() {
        while true {
            let client = Darwin.accept(socketFD, nil, nil)
            guard client >= 0 else { return }
            handleClient(client)
        }
    }

    private func handleClient(_ fd: Int32) {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        guard getpeereid(fd, &effectiveUID, &effectiveGID) == 0,
              effectiveUID == geteuid() else { close(fd); return }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count < 4_096 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
            if count < buffer.count { break }
        }
        close(fd)
        guard data.count <= 4_096 else { return }
        queue.async { [self] in accept(data: data) }
    }

    private func accept(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["sessionID"] as? String,
              !sessionID.isEmpty,
              let identity = accountProvider.accountIdentity else { return }
        let epoch = accountProvider.accountEpoch
        let receivedAt = now()
        let promptMark = object["promptMark"] as? String ?? ""
        let windows = parseWindows(object, at: now())
        guard !windows.isEmpty else { return }
        let signature = signature(for: sessionID, windows: windows, promptMark: promptMark)
        if sessions.count >= 32, sessions[sessionID] == nil,
           let oldest = sessions.min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt })?.key {
            sessions.removeValue(forKey: oldest)
        }
        if var session = sessions[sessionID] {
            session.lastUsedAt = now()
            defer { sessions[sessionID] = session }
            guard session.firstSeenEpoch == epoch else { return }
            guard session.lastSignature != signature else { return }
            for (window, value) in windows {
                if let previous = session.lastValues[window],
                   value.reset == previous.reset, value.used < previous.used { return }
            }
            session.lastSignature = signature
            session.lastValues.merge(windows) { _, new in new }
            guard !identityConflict else { return }
            emit(windows: windows, identity: identity, epoch: epoch, receivedAt: receivedAt)
            session.lastAcceptedAt = receivedAt
            recomputeConflict()
        } else {
            sessions[sessionID] = SessionState(
                firstSeenEpoch: epoch, lastSignature: signature, lastValues: windows,
                lastAcceptedAt: nil, lastUsedAt: now())
        }
    }

    private func parseWindows(_ object: [String: Any], at date: Date) -> [QuotaWindowKind: WindowValue] {
        var result: [QuotaWindowKind: WindowValue] = [:]
        for (key, kind, duration) in [("fiveHour", QuotaWindowKind.fiveHour, 5 * 3_600.0), ("sevenDay", .sevenDay, 7 * 86_400.0)] {
            guard let raw = object[key] as? [String: Any],
                  let used = (raw["usedPercentage"] as? NSNumber)?.doubleValue,
                  (0...100).contains(used), used.isFinite else { continue }
            let reset = (raw["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let reset, !(reset >= date.addingTimeInterval(-86_400) && reset <= date.addingTimeInterval(duration + 3_600)) { continue }
            result[kind] = WindowValue(used: used, reset: reset)
        }
        return result
    }

    private func signature(for sessionID: String, windows: [QuotaWindowKind: WindowValue], promptMark: String) -> String {
        let parts = windows.keys.sorted(by: { $0.rawValue < $1.rawValue }).map { kind in
            let value = windows[kind]!
            return "\(kind.rawValue):\(value.used):\(value.reset?.timeIntervalSince1970 ?? -1)"
        }
        return ([sessionID, promptMark] + parts).joined(separator: "|")
    }

    private func emit(windows: [QuotaWindowKind: WindowValue], identity: AccountIdentity, epoch: AccountEpoch, receivedAt: Date) {
        for (window, value) in windows {
            guard !identityConflict,
                  let observation = QuotaObservation(window: window, usedPercentage: value.used,
                    resetsAt: value.reset, observedAt: nil, receivedAt: receivedAt,
                    source: Self.identifier, trust: .b, accountID: identity.stableID, epoch: epoch) else { continue }
            handler?(observation)
        }
    }

    private func recomputeConflict() {
        guard !gradeAResets.isEmpty else { return }
        let conflict = gradeAResets.contains { window, expected in
            let values = sessions.values.compactMap { $0.lastValues[window]?.reset?.timeIntervalSince1970.rounded() }
            guard let expected = expected?.timeIntervalSince1970.rounded(), !values.isEmpty else { return false }
            return values.contains(expected) && values.contains(where: { $0 != expected })
        }
        identityConflict = conflict
        tracker.markIdentityConflict(conflict)
    }
}
