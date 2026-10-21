import Foundation

/// A read-only look at why and when the next official Claude quota read can happen: what the scheduler allows
/// (minimum interval, request tokens, 429 cooldown, 401 pause) plus how fresh the Mod's data is. Shown live in
/// Settings next to the refresh frequency, so the rules need no explanation to be understood.
struct ClaudeRefreshStatus: Equatable {
    var scheduler: FetchSchedulerStatus
    /// When the newest trusted real-time (Mod) reading was accepted, `nil` when there is none.
    var realtimeAt: Date?
    /// How long such a reading keeps the official read away.
    var realtimeFreshnessWindow: TimeInterval

    enum Phase: Equatable {
        case reading
        case loginExpired
        case rateLimited(remaining: TimeInterval)
        /// The Mod's data is fresh, so the official endpoint is not asked.
        case liveFresh(age: TimeInterval)
        /// The next automatic refresh is `remaining` seconds away; `total` runs from the last refresh to then, so the
        /// bar fills once instead of starting over when one reason (the minimum interval) hands over to the other
        /// (the request budget).
        case waiting(remaining: TimeInterval, total: TimeInterval)
        case ready
    }

    /// What is holding the next automatic read back at `now`, most blocking reason first.
    func phase(now: Date) -> Phase {
        let s = scheduler
        if s.isUnauthorizedPaused { return .loginExpired }
        let cooldown = max(0, s.cooldownRemaining - max(0, now.timeIntervalSince(s.at)))
        if cooldown > 0 { return .rateLimited(remaining: cooldown) }
        if s.isBusy { return .reading }
        if let realtimeAt {
            let age = now.timeIntervalSince(realtimeAt)
            if age >= 0, age < realtimeFreshnessWindow { return .liveFresh(age: age) }
        }
        if let next = nextAutomaticAt(now: now), next > now {
            let remaining = next.timeIntervalSince(now)
            let total = s.lastDispatchAt.map { next.timeIntervalSince($0) } ?? remaining
            return .waiting(remaining: remaining, total: max(remaining, total))
        }
        return .ready
    }

    /// Whether "Refresh Now" would actually read right now, and if not, why. Mirrors the scheduler's manual path, in
    /// its order, so the menu can grey the item out instead of letting a click be skipped silently.
    enum ManualRefresh: Equatable {
        case now
        case loginExpired
        case rateLimited(remaining: TimeInterval)
        case reading
        /// Read successfully within the manual window: a refresh would be skipped as unnecessary.
        case justRead(remaining: TimeInterval)
        /// The Mod delivered within the manual window: a refresh would be answered by that data, not a read.
        case alreadyFresh
        /// The request budget is spent until the next point arrives.
        case noPoints(remaining: TimeInterval)

        var isAvailable: Bool { self == .now }
    }

    func manualRefresh(now: Date) -> ManualRefresh {
        let s = scheduler
        if s.isUnauthorizedPaused { return .loginExpired }
        let cooldown = s.cooldownRemaining - max(0, now.timeIntervalSince(s.at))
        if cooldown > 0 { return .rateLimited(remaining: cooldown) }
        if s.isBusy { return .reading }
        if let last = s.lastSuccessAt {
            let remaining = last.addingTimeInterval(s.manualRefreshWindow).timeIntervalSince(now)
            if remaining > 0 { return .justRead(remaining: remaining) }
        }
        if let realtimeAt, now.timeIntervalSince(realtimeAt) >= 0, now.timeIntervalSince(realtimeAt) < s.manualRefreshWindow {
            return .alreadyFresh
        }
        if tokensAvailable(at: now) < s.manualTokenCost {
            return .noPoints(remaining: max(0, (nextTokenArrival(after: now) ?? now).timeIntervalSince(now)))
        }
        return .now
    }

    /// The earliest moment both rules let an automatic refresh through: the minimum interval since the last request
    /// and enough request points. `nil` when nothing holds it back.
    func nextAutomaticAt(now: Date) -> Date? {
        let s = scheduler
        var candidates: [Date] = []
        if let last = s.lastDispatchAt { candidates.append(last.addingTimeInterval(s.automaticMinimumInterval)) }
        let missing = s.automaticTokenCost - tokensAvailable(at: now)
        if missing > 0, let first = nextTokenArrival(after: now) {
            candidates.append(first.addingTimeInterval(Double(missing - 1) * s.tokenRefillInterval))
        }
        return candidates.max()
    }

    /// When the next point arrives after `now`, rolling the snapshot's arrival forward past the ones already earned.
    private func nextTokenArrival(after now: Date) -> Date? {
        let s = scheduler
        guard let next = s.nextTokenAt, s.tokenRefillInterval > 0 else { return nil }
        guard now >= next else { return next }
        let earned = 1 + Int(now.timeIntervalSince(next) / s.tokenRefillInterval)
        return next.addingTimeInterval(Double(earned) * s.tokenRefillInterval)
    }

    /// Request tokens at `now`, counting the ones earned since the snapshot was taken.
    func tokensAvailable(at now: Date) -> Int {
        let s = scheduler
        guard s.tokens < s.tokenCapacity, let next = s.nextTokenAt, s.tokenRefillInterval > 0 else { return s.tokens }
        let earned = now >= next ? 1 + Int(now.timeIntervalSince(next) / s.tokenRefillInterval) : 0
        return min(s.tokenCapacity, s.tokens + earned)
    }
}
