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
        /// Read recently; `elapsed` of `total` seconds of the minimum interval have passed.
        case waitingInterval(remaining: TimeInterval, total: TimeInterval)
        /// Not enough request tokens for an automatic read yet.
        case waitingTokens(remaining: TimeInterval, total: TimeInterval)
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
        if let last = s.lastDispatchAt {
            let remaining = last.addingTimeInterval(s.automaticMinimumInterval).timeIntervalSince(now)
            if remaining > 0 { return .waitingInterval(remaining: remaining, total: s.automaticMinimumInterval) }
        }
        let tokens = tokensAvailable(at: now)
        if tokens < s.automaticTokenCost {
            let missing = s.automaticTokenCost - tokens
            let first = (s.nextTokenAt ?? now).timeIntervalSince(now)
            let remaining = max(0, first) + Double(max(0, missing - 1)) * s.tokenRefillInterval
            return .waitingTokens(remaining: remaining, total: Double(missing) * s.tokenRefillInterval)
        }
        return .ready
    }

    /// Request tokens at `now`, counting the ones earned since the snapshot was taken.
    func tokensAvailable(at now: Date) -> Int {
        let s = scheduler
        guard s.tokens < s.tokenCapacity, let next = s.nextTokenAt, s.tokenRefillInterval > 0 else { return s.tokens }
        let earned = now >= next ? 1 + Int(now.timeIntervalSince(next) / s.tokenRefillInterval) : 0
        return min(s.tokenCapacity, s.tokens + earned)
    }
}
