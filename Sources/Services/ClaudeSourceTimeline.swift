import CryptoKit
import Foundation

/// Short history of Claude quota source activity for the Advanced settings timeline.
///
/// A pure observer: it records source readings and fetch activity but never feeds back into
/// merging or scheduling. Persisted values are limited to 5h/7d percentages and reset times.
/// History survives a relaunch only for the same account; the file stores a hash, not its ID.
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

    enum Window: String, Equatable, CaseIterable {
        case fiveHour
        case sevenDay
    }

    struct WindowValue: Equatable {
        var usedPercentage: Double
        var resetAt: Date?
    }

    enum ReadingDisposition: String, Equatable {
        case displayed
        case freshnessEvidenceWithinTolerance
        case freshnessEvidenceBelowDisplay
        case freshnessEvidence
    }

    /// One adopted reading and how long it counted as valid.
    struct Reading: Equatable {
        var source: StatusSlotLiveSource
        var observedAt: Date
        var expiresAt: Date
        var windows: [Window: WindowValue] = [:]
        var windowObservedAt: [Window: Date] = [:]
        var dispositions: [Window: ReadingDisposition] = [:]
    }

    enum RequestOutcome: Equatable {
        case success
        case failure(FailureKind)
        case interrupted
    }

    struct Request: Equatable {
        var trigger: FetchDispatchTrigger
        var startedAt: Date
        var completedAt: Date?
        var outcome: RequestOutcome?
        var sourceExpiryAt: Date?
        var windows: [Window: WindowValue] = [:]
        var dispositions: [Window: ReadingDisposition] = [:]
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
        var requests: [Request] = []
        var estimate: FetchAutomaticRequestEstimate?

        static let empty = Snapshot(readings: [], failures: [], requests: [], estimate: nil)
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
    private var requests: [Request] = []
    private var estimate: FetchAutomaticRequestEstimate?
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
        recordReading(source: source, observedAt: observedAt, values: [:], dispositions: [:])
    }

    func recordReading(
        source: StatusSlotLiveSource,
        observedAt: Date,
        values: [Window: WindowValue],
        dispositions: [Window: ReadingDisposition]
    ) {
        let changed = lock.withLock { () -> Bool in
            if let index = readings.lastIndex(where: {
                $0.source == source && abs($0.observedAt.timeIntervalSince(observedAt)) < Self.pairTolerance
            }) {
                let prior = readings[index]
                readings[index].windows.merge(values) { _, new in new }
                readings[index].windowObservedAt.merge(
                    Dictionary(uniqueKeysWithValues: values.keys.map { ($0, observedAt) })) { _, new in new }
                readings[index].dispositions.merge(dispositions) { _, new in new }
                let perWindowExpiry = readings[index].windows.keys.map { window in
                    readings[index].windowObservedAt[window, default: observedAt]
                        .addingTimeInterval(validity().seconds(for: source))
                }.min()
                readings[index].expiresAt = perWindowExpiry
                    ?? min(prior.expiresAt, observedAt.addingTimeInterval(validity().seconds(for: source)))
                guard readings[index] != prior else { return false }
            } else {
                let reading = Reading(
                    source: source, observedAt: observedAt,
                    expiresAt: observedAt.addingTimeInterval(validity().seconds(for: source)),
                    windows: values,
                    windowObservedAt: Dictionary(uniqueKeysWithValues: values.keys.map { ($0, observedAt) }),
                    dispositions: dispositions)
                let index = readings.lastIndex(where: { $0.observedAt <= observedAt }).map { $0 + 1 } ?? 0
                readings.insert(reading, at: index)
            }
            pruneLocked(at: now())
            return true
        }
        if changed { notify() }
    }

    func recordRequestDispatched(trigger: FetchDispatchTrigger, at date: Date, sourceExpiryAt: Date?) {
        lock.withLock {
            requests.append(Request(
                trigger: trigger, startedAt: date, completedAt: nil, outcome: nil,
                sourceExpiryAt: sourceExpiryAt))
            pruneLocked(at: now())
        }
        notify()
    }

    func recordRequestCompleted(
        trigger: FetchDispatchTrigger,
        startedAt: Date,
        completedAt: Date,
        outcome: RequestOutcome,
        values: [Window: WindowValue] = [:],
        dispositions: [Window: ReadingDisposition] = [:]
    ) {
        let changed = lock.withLock { () -> Bool in
            guard let index = requests.lastIndex(where: {
                $0.trigger == trigger && $0.startedAt == startedAt && $0.completedAt == nil
            }) else { return false }
            requests[index].completedAt = completedAt
            requests[index].outcome = outcome
            requests[index].windows = values
            requests[index].dispositions = dispositions
            pruneLocked(at: now())
            return true
        }
        if changed { notify() }
    }

    func updateEstimate(_ estimate: FetchAutomaticRequestEstimate) {
        let changed = lock.withLock { () -> Bool in
            guard self.estimate != estimate else { return false }
            self.estimate = estimate
            return true
        }
        if changed { onChange?() }
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
    func recordOfficialSuccess(
        at date: Date,
        values: [Window: WindowValue] = [:],
        dispositions: [Window: ReadingDisposition] = [:]
    ) {
        let closed = lock.withLock { () -> Bool in
            guard let last = failures.indices.last, failures[last].end == nil else { return false }
            failures[last].end = max(date, failures[last].start)
            return true
        }
        if closed { notify() }
        recordReading(source: .oauthAPI, observedAt: date, values: values, dispositions: dispositions)
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
                let sourceExpiry = reading.windows.keys.map { window in
                    reading.windowObservedAt[window, default: reading.observedAt]
                        .addingTimeInterval(current.seconds(for: reading.source))
                }.min() ?? reading.observedAt.addingTimeInterval(current.seconds(for: reading.source))
                let expiresAt = max(sourceExpiry, date)
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
            guard !readings.isEmpty || !failures.isEmpty || !requests.isEmpty || estimate != nil || keyChanged else { return false }
            readings.removeAll()
            failures.removeAll()
            requests.removeAll()
            estimate = nil
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
            let restoredRequests = saved.requests.compactMap(\.request).map { request -> Request in
                guard request.completedAt == nil else { return request }
                var interrupted = request
                interrupted.completedAt = max(savedAt, request.startedAt)
                interrupted.outcome = .interrupted
                return interrupted
            }
            requests = (restoredRequests + requests).sorted { $0.startedAt < $1.startedAt }
            pruneLocked(at: now())
            return !restoredReadings.isEmpty || !restoredFailures.isEmpty || !restoredRequests.isEmpty
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
            return Snapshot(readings: readings, failures: failures, requests: requests, estimate: estimate)
        }
    }

    private func pruneLocked(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        readings.removeAll { $0.expiresAt < cutoff }
        if readings.count > Self.maximumReadings {
            readings.removeFirst(readings.count - Self.maximumReadings)
        }
        failures.removeAll { ($0.end ?? .distantFuture) < cutoff }
        requests.removeAll { ($0.completedAt ?? .distantFuture) < cutoff }
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
                failures: failures.map(StoredHistory.StoredRun.init),
                requests: requests.map(StoredHistory.StoredRequest.init))
        }
        guard let history, let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// On-disk form of the history: plain times, source names and failure categories only.
private struct StoredHistory: Codable {
    static let currentVersion = 2

    struct StoredReading: Codable {
        var source: String
        var observedAt: TimeInterval
        var expiresAt: TimeInterval
        var windows: [String: StoredWindowValue]
        var windowObservedAt: [String: TimeInterval]
        var dispositions: [String: String]

        private static let sources: [(String, StatusSlotLiveSource)] = [
            ("oauth", .oauthAPI), ("mod", .mod),
        ]

        init(_ reading: ClaudeSourceTimeline.Reading) {
            source = Self.sources.first { $0.1 == reading.source }?.0 ?? "oauth"
            observedAt = reading.observedAt.timeIntervalSince1970
            expiresAt = reading.expiresAt.timeIntervalSince1970
            windows = Dictionary(uniqueKeysWithValues: reading.windows.map { ($0.key.rawValue, StoredWindowValue($0.value)) })
            windowObservedAt = Dictionary(uniqueKeysWithValues: reading.windowObservedAt.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) })
            dispositions = Dictionary(uniqueKeysWithValues: reading.dispositions.map { ($0.key.rawValue, $0.value.rawValue) })
        }

        var reading: ClaudeSourceTimeline.Reading? {
            guard let source = Self.sources.first(where: { $0.0 == self.source })?.1 else { return nil }
            return .init(
                source: source, observedAt: Date(timeIntervalSince1970: observedAt),
                expiresAt: Date(timeIntervalSince1970: expiresAt),
                windows: Dictionary(uniqueKeysWithValues: windows.compactMap { key, value in
                    guard let window = ClaudeSourceTimeline.Window(rawValue: key) else { return nil }
                    return (window, value.value)
                }),
                windowObservedAt: Dictionary(uniqueKeysWithValues: windowObservedAt.compactMap { key, value in
                    guard let window = ClaudeSourceTimeline.Window(rawValue: key) else { return nil }
                    return (window, Date(timeIntervalSince1970: value))
                }),
                dispositions: Dictionary(uniqueKeysWithValues: dispositions.compactMap { key, value in
                    guard let window = ClaudeSourceTimeline.Window(rawValue: key),
                          let disposition = ClaudeSourceTimeline.ReadingDisposition(rawValue: value) else { return nil }
                    return (window, disposition)
                }))
        }
    }

    struct StoredWindowValue: Codable {
        var usedPercentage: Double
        var resetAt: TimeInterval?

        init(_ value: ClaudeSourceTimeline.WindowValue) {
            usedPercentage = value.usedPercentage
            resetAt = value.resetAt?.timeIntervalSince1970
        }

        var value: ClaudeSourceTimeline.WindowValue {
            .init(usedPercentage: usedPercentage, resetAt: resetAt.map(Date.init(timeIntervalSince1970:)))
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

    struct StoredRequest: Codable {
        var trigger: String
        var startedAt: TimeInterval
        var completedAt: TimeInterval?
        var outcome: String?
        var sourceExpiryAt: TimeInterval?
        var windows: [String: StoredWindowValue]
        var dispositions: [String: String]

        init(_ request: ClaudeSourceTimeline.Request) {
            trigger = request.trigger.rawValue
            startedAt = request.startedAt.timeIntervalSince1970
            completedAt = request.completedAt?.timeIntervalSince1970
            sourceExpiryAt = request.sourceExpiryAt?.timeIntervalSince1970
            switch request.outcome {
            case .success?: outcome = "success"
            case let .failure(kind)?: outcome = "failure:" + StoredRun(.init(start: request.startedAt, end: nil, kind: kind)).kind
            case .interrupted?: outcome = "interrupted"
            case nil: outcome = nil
            }
            windows = Dictionary(uniqueKeysWithValues: request.windows.map { ($0.key.rawValue, StoredWindowValue($0.value)) })
            dispositions = Dictionary(uniqueKeysWithValues: request.dispositions.map { ($0.key.rawValue, $0.value.rawValue) })
        }

        var request: ClaudeSourceTimeline.Request? {
            guard let trigger = FetchDispatchTrigger(rawValue: trigger) else { return nil }
            let decodedOutcome: ClaudeSourceTimeline.RequestOutcome?
            if outcome == "success" { decodedOutcome = .success }
            else if outcome == "interrupted" { decodedOutcome = .interrupted }
            else if let outcome, outcome.hasPrefix("failure:"),
                    let kind = Self.failureKind(String(outcome.dropFirst("failure:".count))) {
                decodedOutcome = .failure(kind)
            } else { decodedOutcome = nil }
            return .init(
                trigger: trigger, startedAt: Date(timeIntervalSince1970: startedAt),
                completedAt: completedAt.map(Date.init(timeIntervalSince1970:)), outcome: decodedOutcome,
                sourceExpiryAt: sourceExpiryAt.map(Date.init(timeIntervalSince1970:)),
                windows: Dictionary(uniqueKeysWithValues: windows.compactMap { key, value in
                    guard let window = ClaudeSourceTimeline.Window(rawValue: key) else { return nil }
                    return (window, value.value)
                }),
                dispositions: Dictionary(uniqueKeysWithValues: dispositions.compactMap { key, value in
                    guard let window = ClaudeSourceTimeline.Window(rawValue: key),
                          let disposition = ClaudeSourceTimeline.ReadingDisposition(rawValue: value) else { return nil }
                    return (window, disposition)
                }))
        }

        private static func failureKind(_ raw: String) -> ClaudeSourceTimeline.FailureKind? {
            switch raw {
            case "network": return .network
            case "rateLimited": return .rateLimited
            case "unauthorized": return .unauthorized
            case "serverError": return .serverError
            case "missingCredentials": return .missingCredentials
            default: return nil
            }
        }
    }

    var version = currentVersion
    var accountKey: String?
    var savedAt: TimeInterval
    var readings: [StoredReading]
    var failures: [StoredRun]
    var requests: [StoredRequest]
}
