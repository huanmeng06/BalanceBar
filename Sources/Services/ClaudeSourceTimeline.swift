import CryptoKit
import Foundation

/// Short history of Claude quota source activity for the Advanced settings timeline.
///
/// A pure observer: it records what the pipeline already decided (an adopted reading, an official
/// failure) and never feeds back into merging or scheduling. Only times, sources and failure
/// categories are kept (no quota values). With a `fileURL` the history survives a relaunch, but
/// only for the same account: the file carries a hash of the account's stable ID.
final class ClaudeSourceTimeline {
    /// Coarse, non-secret category of a failed official read.
    enum FailureKind: Equatable {
        case network
        case rateLimited
        case unauthorized
        case serverError
        case missingCredentials

        init(_ failure: ClaudeQuotaFailure) {
            switch failure {
            case .transport: self = .network
            case .rateLimited, .http(429): self = .rateLimited
            case .unauthorized, .http(401): self = .unauthorized
            case .http, .invalidResponse: self = .serverError
            case .missingCredentials: self = .missingCredentials
            }
        }
    }

    /// One adopted reading and how long it counted as valid.
    struct Reading: Equatable {
        var source: StatusSlotLiveSource
        var observedAt: Date
        var expiresAt: Date
    }

    /// An unbroken run of failed official reads; `end` is nil while it is still failing.
    struct FailureRun: Equatable {
        var start: Date
        var end: Date?
        var kind: FailureKind
    }

    struct Snapshot: Equatable {
        var readings: [Reading]
        var failures: [FailureRun]

        static let empty = Snapshot(readings: [], failures: [])
    }

    /// Slightly longer than the 60-minute chart so a bar entering from the left edge is complete.
    static let retention: TimeInterval = 65 * 60
    /// The 5h and 7d windows of one reading arrive as two observations a moment apart.
    static let pairTolerance: TimeInterval = 1
    /// Hard bound on memory if a source ever reports far more often than expected.
    static let maximumReadings = 5_000

    private let validity: () -> ClaudeSourceValidity
    private let now: () -> Date
    private let fileURL: URL?
    private let saveDelay: TimeInterval
    private let saveQueue = DispatchQueue(label: "BalanceBar.ClaudeSourceTimeline.save", qos: .utility)
    private let lock = NSLock()
    private var readings: [Reading] = []
    private var failures: [FailureRun] = []
    /// Hashed stable ID of the account this history belongs to; nil until the account is known.
    private var accountKey: String?
    private var saveScheduled = false
    private var changeHandler: (() -> Void)?

    /// - Parameters:
    ///   - fileURL: Where the history is kept across launches; nil keeps it in memory only.
    ///   - saveDelay: Bursts of changes (Mod snapshots every few seconds) are written once.
    init(
        validity: @escaping () -> ClaudeSourceValidity = { .defaults },
        now: @escaping () -> Date = Date.init,
        fileURL: URL? = nil,
        saveDelay: TimeInterval = 1
    ) {
        self.validity = validity
        self.now = now
        self.fileURL = fileURL
        self.saveDelay = saveDelay
    }

    /// Hash of the account's stable ID (account + organization), so the file never stores the ID.
    static func accountKey(forStableID stableID: String?) -> String? {
        guard let stableID, !stableID.isEmpty else { return nil }
        return SHA256.hash(data: Data(stableID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Called on the recording queue after any change.
    var onChange: (() -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    /// Records an adopted reading. Its validity is the source's setting at this moment; a later
    /// setting change only reaches readings still valid then (`validityChanged`).
    func recordReading(source: StatusSlotLiveSource, observedAt: Date) {
        let changed = lock.withLock { () -> Bool in
            guard !readings.contains(where: {
                $0.source == source && abs($0.observedAt.timeIntervalSince(observedAt)) < Self.pairTolerance
            }) else { return false }
            let reading = Reading(
                source: source, observedAt: observedAt,
                expiresAt: observedAt.addingTimeInterval(validity().seconds(for: source)))
            let index = readings.lastIndex(where: { $0.observedAt <= observedAt }).map { $0 + 1 } ?? 0
            readings.insert(reading, at: index)
            pruneLocked(at: now())
            return true
        }
        if changed { notify() }
    }

    /// Opens a failure run. The same category continues the run in progress; a different one
    /// ends it at `date` and opens a new run there, so earlier time keeps its own category.
    func recordFailure(_ kind: FailureKind, at date: Date) {
        let changed = lock.withLock { () -> Bool in
            if let last = failures.indices.last, failures[last].end == nil {
                guard failures[last].kind != kind else { return false }
                failures[last].end = max(date, failures[last].start)
            }
            failures.append(FailureRun(start: date, end: nil, kind: kind))
            pruneLocked(at: now())
            return true
        }
        if changed { notify() }
    }

    /// An official read was adopted: the failure run in progress (if any) ends here.
    func recordOfficialSuccess(at date: Date) {
        let closed = lock.withLock { () -> Bool in
            guard let last = failures.indices.last, failures[last].end == nil else { return false }
            failures[last].end = max(date, failures[last].start)
            return true
        }
        if closed { notify() }
        recordReading(source: .oauthAPI, observedAt: date)
    }

    /// Applies a validity setting change the way the status slot does: readings that already
    /// expired keep their length; readings still valid now are measured with the new setting,
    /// and a shorter setting that would have expired them in the past ends them now.
    func validityChanged() {
        let changed = lock.withLock { () -> Bool in
            let date = now()
            let current = validity()
            var changed = false
            for index in readings.indices where readings[index].expiresAt > date {
                let reading = readings[index]
                let expiresAt = max(reading.observedAt.addingTimeInterval(current.seconds(for: reading.source)), date)
                if expiresAt != reading.expiresAt {
                    readings[index].expiresAt = expiresAt
                    changed = true
                }
            }
            return changed
        }
        if changed { notify() }
    }

    /// Drops everything; the previous account's activity is never shown for the next one. The
    /// file is rewritten for `accountKey`, so a relaunch does not bring the old history back.
    func reset(accountKey: String? = nil) {
        let changed = lock.withLock { () -> Bool in
            let keyChanged = self.accountKey != accountKey
            self.accountKey = accountKey
            guard !readings.isEmpty || !failures.isEmpty || keyChanged else { return false }
            readings.removeAll()
            failures.removeAll()
            return true
        }
        if changed { notify() }
    }

    /// Loads the saved history once the signed-in account is known. A file from another account
    /// (or none at all) is ignored and later overwritten. A failure that was still open when the
    /// app quit ends at the last save: the time BalanceBar was not running is not a failure.
    func restore(accountKey: String?) {
        let saved = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(StoredHistory.self, from: $0) }
        let changed = lock.withLock { () -> Bool in
            self.accountKey = accountKey
            guard let saved, saved.version == StoredHistory.currentVersion,
                  let accountKey, saved.accountKey == accountKey else { return false }
            let savedAt = Date(timeIntervalSince1970: saved.savedAt)
            let current = readings
            let restoredReadings = saved.readings.compactMap(\.reading).filter { old in
                !current.contains { Self.isSameReading($0, old) }
            }
            readings = (restoredReadings + readings).sorted { $0.observedAt < $1.observedAt }
            var restoredFailures = saved.failures.compactMap(\.run)
            for index in restoredFailures.indices where restoredFailures[index].end == nil {
                restoredFailures[index].end = max(savedAt, restoredFailures[index].start)
            }
            failures = (restoredFailures + failures).sorted { $0.start < $1.start }
            pruneLocked(at: now())
            return !restoredReadings.isEmpty || !restoredFailures.isEmpty
        }
        if changed { notify() }
    }

    private static func isSameReading(_ lhs: Reading, _ rhs: Reading) -> Bool {
        lhs.source == rhs.source && abs(lhs.observedAt.timeIntervalSince(rhs.observedAt)) < pairTolerance
    }

    /// Writes any pending change now (tests; normal saves are coalesced).
    func flushPendingSave() {
        saveQueue.sync {}
        saveNow()
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            pruneLocked(at: now())
            return Snapshot(readings: readings, failures: failures)
        }
    }

    private func pruneLocked(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        readings.removeAll { $0.expiresAt < cutoff }
        if readings.count > Self.maximumReadings {
            readings.removeFirst(readings.count - Self.maximumReadings)
        }
        failures.removeAll { ($0.end ?? .distantFuture) < cutoff }
    }

    private func notify() {
        scheduleSave()
        onChange?()
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !saveScheduled else { return false }
            saveScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        saveQueue.asyncAfter(deadline: .now() + saveDelay) { [weak self] in self?.saveNow() }
    }

    private func saveNow() {
        guard let fileURL else { return }
        let history = lock.withLock { () -> StoredHistory? in
            guard saveScheduled else { return nil }
            saveScheduled = false
            pruneLocked(at: now())
            return StoredHistory(
                accountKey: accountKey, savedAt: now().timeIntervalSince1970,
                readings: readings.map(StoredHistory.StoredReading.init),
                failures: failures.map(StoredHistory.StoredRun.init))
        }
        guard let history, let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// On-disk form of the history: plain times, source names and failure categories only.
private struct StoredHistory: Codable {
    static let currentVersion = 1

    struct StoredReading: Codable {
        var source: String
        var observedAt: TimeInterval
        var expiresAt: TimeInterval

        private static let sources: [(String, StatusSlotLiveSource)] = [
            ("oauth", .oauthAPI), ("mod", .mod),
        ]

        init(_ reading: ClaudeSourceTimeline.Reading) {
            source = Self.sources.first { $0.1 == reading.source }?.0 ?? "oauth"
            observedAt = reading.observedAt.timeIntervalSince1970
            expiresAt = reading.expiresAt.timeIntervalSince1970
        }

        var reading: ClaudeSourceTimeline.Reading? {
            guard let source = Self.sources.first(where: { $0.0 == self.source })?.1 else { return nil }
            return .init(
                source: source, observedAt: Date(timeIntervalSince1970: observedAt),
                expiresAt: Date(timeIntervalSince1970: expiresAt))
        }
    }

    struct StoredRun: Codable {
        var start: TimeInterval
        var end: TimeInterval?
        var kind: String

        private static let kinds: [(String, ClaudeSourceTimeline.FailureKind)] = [
            ("network", .network), ("rateLimited", .rateLimited), ("unauthorized", .unauthorized),
            ("serverError", .serverError), ("missingCredentials", .missingCredentials),
        ]

        init(_ run: ClaudeSourceTimeline.FailureRun) {
            start = run.start.timeIntervalSince1970
            end = run.end?.timeIntervalSince1970
            kind = Self.kinds.first { $0.1 == run.kind }?.0 ?? "serverError"
        }

        var run: ClaudeSourceTimeline.FailureRun? {
            guard let kind = Self.kinds.first(where: { $0.0 == self.kind })?.1 else { return nil }
            return .init(
                start: Date(timeIntervalSince1970: start), end: end.map(Date.init(timeIntervalSince1970:)),
                kind: kind)
        }
    }

    var version = currentVersion
    var accountKey: String?
    var savedAt: TimeInterval
    var readings: [StoredReading]
    var failures: [StoredRun]
}
