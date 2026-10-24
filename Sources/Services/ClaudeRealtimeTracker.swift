import Foundation

/// Tracks trusted native Claude Code observations for scheduler suppression.
///
/// Freshness is reported only when both standard windows belong to the same account
/// epoch and neither a reset nor an identity conflict is pending.
final class ClaudeRealtimeTracker: RealtimeSourceFreshnessProviding, ManualRefreshFreePathChecking {
    private let freshness: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()

    private var epoch: AccountEpoch?
    private var lastTrusted: [QuotaWindowKind: Date] = [:]
    private var pendingReset: Date?
    private var identityConflict = false

    init(freshness: TimeInterval = 120, now: @escaping () -> Date = Date.init) {
        self.freshness = freshness
        self.now = now
    }

    var lastTrustedRealtimeObservationAt: Date? {
        lock.withLock { bothWindowsFreshUntilLocked(at: now()).map { $0 - freshness } }
    }

    var bothWindowsFreshUntil: Date? {
        lock.withLock { bothWindowsFreshUntilLocked(at: now()) }
    }

    var pendingResetOf: Date? {
        lock.withLock { pendingReset }
    }

    func recordTrustedObservation(window: QuotaWindowKind, receivedAt: Date, epoch: AccountEpoch) {
        guard window == .fiveHour || window == .sevenDay else { return }
        lock.withLock {
            if self.epoch != epoch {
                self.epoch = epoch
                lastTrusted.removeAll()
                pendingReset = nil
                identityConflict = false
            }
            lastTrusted[window] = receivedAt
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

    func checkFreePath(within window: TimeInterval, completion: @escaping (Bool) -> Void) {
        let satisfied = lock.withLock {
            guard let until = bothWindowsFreshUntilLocked(at: now()) else { return false }
            return until.timeIntervalSince(now()) >= max(0, freshness - window)
        }
        completion(satisfied)
    }

    private func bothWindowsFreshUntilLocked(at date: Date) -> Date? {
        guard pendingReset == nil, !identityConflict,
              let five = lastTrusted[.fiveHour], let seven = lastTrusted[.sevenDay] else { return nil }
        let until = min(five, seven).addingTimeInterval(freshness)
        return until > date ? until : nil
    }
}
