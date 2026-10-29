import Foundation

/// Tracks trusted native Claude Code observations for scheduler suppression.
///
/// Freshness is reported only when both standard windows belong to the same account
/// epoch and neither a reset nor an identity conflict is pending. How long an observation
/// stays fresh is the user's per-source validity (Mod).
final class ClaudeRealtimeTracker: RealtimeSourceFreshnessProviding, ManualRefreshFreePathChecking {
    private let validity: () -> ClaudeSourceValidity
    private let now: () -> Date
    private let lock = NSLock()

    private var epoch: AccountEpoch?
    private var lastTrusted: [QuotaWindowKind: (at: Date, source: StatusSlotLiveSource)] = [:]
    private var pendingReset: Date?
    private var identityConflict = false

    init(validity: @escaping () -> ClaudeSourceValidity = { .defaults }, now: @escaping () -> Date = Date.init) {
        self.validity = validity
        self.now = now
    }

    /// Fixed local-source freshness (tests).
    convenience init(freshness: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.init(
            validity: { ClaudeSourceValidity(oauth: ClaudeSourceValidity.defaults.oauth, mod: freshness) },
            now: now)
    }

    var lastTrustedRealtimeObservationAt: Date? {
        lock.withLock {
            guard bothWindowsFreshUntilLocked(at: now()) != nil else { return nil }
            return lastTrusted.values.map(\.at).min()
        }
    }

    var realtimeFreshUntil: Date? {
        lock.withLock { bothWindowsFreshUntilLocked(at: now()) }
    }

    var bothWindowsFreshUntil: Date? {
        lock.withLock { bothWindowsFreshUntilLocked(at: now()) }
    }

    var pendingResetOf: Date? {
        lock.withLock { pendingReset }
    }

    /// Records a trusted native observation for freshness.
    ///
    /// `observedAt` is the time the observation was produced at the source (the snapshot's
    /// own timestamp when it carries one, otherwise the local receipt time). Rescanning an
    /// old file therefore cannot extend freshness: its observation time stays in the past.
    func recordTrustedObservation(
        window: QuotaWindowKind, observedAt: Date, epoch: AccountEpoch, source: StatusSlotLiveSource = .mod
    ) {
        guard window == .fiveHour || window == .sevenDay else { return }
        lock.withLock {
            if self.epoch != epoch {
                self.epoch = epoch
                lastTrusted.removeAll()
                pendingReset = nil
                identityConflict = false
            }
            lastTrusted[window] = (observedAt, source)
        }
    }

    func markPendingReset(_ resetsAt: Date?) {
        lock.withLock { pendingReset = resetsAt }
    }

    func markIdentityConflict(_ conflict: Bool) {
        lock.withLock { identityConflict = conflict }
    }

    func reset(epoch: AccountEpoch) {
        lock.withLock {
            self.epoch = epoch
            lastTrusted.removeAll()
            pendingReset = nil
            identityConflict = false
        }
    }

    /// Drops one source's trusted observations so it no longer counts as fresh. The other
    /// source's observations (and the account epoch) are kept.
    func invalidate(source: StatusSlotLiveSource) {
        lock.withLock { lastTrusted = lastTrusted.filter { $0.value.source != source } }
    }

    func checkFreePath(within window: TimeInterval, completion: @escaping (Bool) -> Void) {
        let satisfied = lock.withLock {
            let date = now()
            guard bothWindowsFreshUntilLocked(at: date) != nil,
                  let oldest = lastTrusted.values.map(\.at).min() else { return false }
            return date.timeIntervalSince(oldest) <= max(0, window)
        }
        completion(satisfied)
    }

    /// The earlier of the two windows' expiry, each measured with its own source's validity.
    private func bothWindowsFreshUntilLocked(at date: Date) -> Date? {
        guard pendingReset == nil, !identityConflict,
              let five = lastTrusted[.fiveHour], let seven = lastTrusted[.sevenDay] else { return nil }
        let current = validity()
        let until = min(
            five.at.addingTimeInterval(current.seconds(for: five.source)),
            seven.at.addingTimeInterval(current.seconds(for: seven.source)))
        return until > date ? until : nil
    }
}
