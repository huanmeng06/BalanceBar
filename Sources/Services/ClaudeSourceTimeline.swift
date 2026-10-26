import Foundation

/// Short in-memory history of Claude quota source activity for the Advanced settings timeline.
///
/// A pure observer: it records what the pipeline already decided (an adopted reading, an official
/// failure) and never feeds back into merging or scheduling. Nothing is persisted and no quota
/// values are kept, only times and sources.
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
    private let lock = NSLock()
    private var readings: [Reading] = []
    private var failures: [FailureRun] = []
    private var changeHandler: (() -> Void)?

    init(validity: @escaping () -> ClaudeSourceValidity = { .defaults }, now: @escaping () -> Date = Date.init) {
        self.validity = validity
        self.now = now
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

    /// Opens a failure run, or updates the category of the one in progress.
    func recordFailure(_ kind: FailureKind, at date: Date) {
        let changed = lock.withLock { () -> Bool in
            if let last = failures.indices.last, failures[last].end == nil {
                guard failures[last].kind != kind else { return false }
                failures[last].kind = kind
                return true
            }
            failures.append(FailureRun(start: date, end: nil, kind: kind))
            pruneLocked(at: now())
            return true
        }
        if changed { notify() }
    }

    /// An official read was adopted: the failure run in progress (if any) ends here.
    func recordOfficialSuccess(at date: Date) {
        lock.withLock {
            if let last = failures.indices.last, failures[last].end == nil {
                failures[last].end = max(date, failures[last].start)
            }
        }
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

    /// Drops everything; the previous account's activity is never shown for the next one.
    func reset() {
        let changed = lock.withLock { () -> Bool in
            guard !readings.isEmpty || !failures.isEmpty else { return false }
            readings.removeAll()
            failures.removeAll()
            return true
        }
        if changed { notify() }
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
        onChange?()
    }
}
