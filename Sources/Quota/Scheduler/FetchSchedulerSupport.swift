import Foundation

/// Time source used by the fetch scheduler; tests inject a fake clock.
public protocol SchedulerClock {
    /// The current time.
    var now: Date { get }
}

/// Wall-clock implementation of `SchedulerClock`.
public struct SystemSchedulerClock: SchedulerClock {
    public init() {}
    public var now: Date { Date() }
}

/// Defers work for the scheduler's coalescing window; tests inject a manual timer.
public protocol SchedulerTimer {
    /// Runs `work` once after `delay` seconds on an unspecified queue.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

/// `DispatchQueue`-backed implementation of `SchedulerTimer`.
public struct DispatchSchedulerTimer: SchedulerTimer {
    private let queue: DispatchQueue
    public init(queue: DispatchQueue = .global(qos: .utility)) { self.queue = queue }
    public func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }
}

/// Classified outcome of one Usage API request.
public enum UsageFetchResult: Equatable {
    /// HTTP 2xx with the raw response body.
    case success(Data)
    /// HTTP 429 with the raw `Retry-After` header value, if present.
    case rateLimited(retryAfter: String?)
    /// HTTP 401.
    case unauthorized
    /// Any other failure, with a non-secret diagnostic description.
    case failure(String)
}

/// Performs the single Usage API request; tests inject a fake transport.
public protocol UsageFetchTransport {
    /// Starts one request and calls `completion` exactly once on any queue.
    func fetchUsage(completion: @escaping (UsageFetchResult) -> Void)
}

/// Free-path check performed before a manual refresh spends a request.
public protocol ManualRefreshFreePathChecking {
    /// Reports `true` when a free source produced trusted data within `window` seconds,
    /// so no Usage API request is needed. `completion` may be called on any queue.
    func checkFreePath(within window: TimeInterval, completion: @escaping (Bool) -> Void)
}

/// Reports when a trusted real-time source (the BalanceBar Mod) last delivered data.
public protocol RealtimeSourceFreshnessProviding {
    /// Receipt time of the latest trusted real-time observation, or `nil`.
    var lastTrustedRealtimeObservationAt: Date? { get }
}

/// Scheduler state that must survive app restarts.
public struct FetchSchedulerPersistentState: Codable, Equatable {
    /// End of the current 429 cooldown, if any.
    public var cooldownUntil: Date?
    /// Consecutive 429 responses without a usable `Retry-After`, driving 15 → 30 → 60 minute backoff.
    public var consecutiveRateLimitBackoffs: Int
    /// Credential version that received 401; requests pause until the version changes.
    public var unauthorizedCredentialVersion: CredentialVersion?
    /// Whether a 401 pause is active (also covers a 401 while no version was known).
    public var isUnauthorizedPaused: Bool

    public init(
        cooldownUntil: Date? = nil,
        consecutiveRateLimitBackoffs: Int = 0,
        unauthorizedCredentialVersion: CredentialVersion? = nil,
        isUnauthorizedPaused: Bool = false
    ) {
        self.cooldownUntil = cooldownUntil
        self.consecutiveRateLimitBackoffs = consecutiveRateLimitBackoffs
        self.unauthorizedCredentialVersion = unauthorizedCredentialVersion
        self.isUnauthorizedPaused = isUnauthorizedPaused
    }
}

/// Loads and saves scheduler state. Called only on the scheduler's background queue.
public protocol FetchSchedulerStateStoring {
    func load() -> FetchSchedulerPersistentState?
    func save(_ state: FetchSchedulerPersistentState)
}

/// JSON-file implementation of `FetchSchedulerStateStoring`.
public final class FileFetchSchedulerStateStore: FetchSchedulerStateStoring {
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() -> FetchSchedulerPersistentState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(FetchSchedulerPersistentState.self, from: data)
    }

    public func save(_ state: FetchSchedulerPersistentState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Parses an HTTP `Retry-After` value (delta-seconds or HTTP-date) into seconds from `now`.
/// Returns `nil` when missing, malformed, zero, or in the past.
public enum RetryAfterParser {
    public static func seconds(from value: String?, now: Date) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.allSatisfy(\.isNumber) {
            guard let seconds = TimeInterval(raw), seconds > 0 else { return nil }
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                let delta = date.timeIntervalSince(now)
                return delta > 0 ? delta : nil
            }
        }
        return nil
    }
}

/// Tunable scheduler values. Defaults come from `QuotaConstants`.
public struct FetchSchedulerConfiguration: Equatable {
    public var automaticMinimumInterval: TimeInterval = QuotaConstants.automaticRequestMinimumInterval
    public var minimumCooldown: TimeInterval = QuotaConstants.minimumCooldown
    /// Upper bound for the 429 doubling backoff (15 → 30 → 60 minutes).
    public var maximumBackoffCooldown: TimeInterval = 4 * QuotaConstants.minimumCooldown
    public var tokenCapacity: Int = QuotaConstants.requestTokenBucketCapacity
    public var tokenRefillInterval: TimeInterval = QuotaConstants.requestTokenRefillInterval
    public var automaticTokenCost: Int = QuotaConstants.automaticRequestTokenCost
    public var manualTokenCost: Int = QuotaConstants.manualRequestTokenCost
    public var manualRefreshWindow: TimeInterval = QuotaConstants.manualRefreshWindow
    public var realtimeSourceFreshness: TimeInterval = QuotaConstants.realtimeSourceFreshness
    /// Requests arriving within this window are merged into one evaluation.
    /// Not yet in `QuotaConstants`; candidate for promotion there.
    public var coalescingWindow: TimeInterval = 1

    public init() {}
}

/// A read-only snapshot of what the scheduler allows right now (for Settings; never used to decide anything).
public struct FetchSchedulerStatus: Equatable {
    public var tokens: Int
    public var tokenCapacity: Int
    public var tokenRefillInterval: TimeInterval
    /// When the next request token arrives, `nil` while the bucket is full.
    public var nextTokenAt: Date?
    public var automaticTokenCost: Int
    public var lastDispatchAt: Date?
    public var automaticMinimumInterval: TimeInterval
    /// Last successful read for the current account.
    public var lastSuccessAt: Date?
    /// A read for the current account that failed (transport or server error) after the last success; `nil` once a
    /// read succeeds again. 429 and 401 have their own fields.
    public var lastFailureAt: Date? = nil
    /// Remaining 429 cooldown at `at`.
    public var cooldownRemaining: TimeInterval
    public var isUnauthorizedPaused: Bool
    public var isBusy: Bool
    /// When the snapshot was taken.
    public var at: Date
}

/// Why a request was skipped instead of sent.
public enum FetchSkipReason: String, Equatable {
    case coalescedIntoInFlight = "coalesced_in_flight"
    case cooldown
    case unauthorizedPaused = "unauthorized_paused"
    case minimumInterval = "minimum_interval"
    case insufficientTokens = "insufficient_tokens"
    case realtimeSourceFresh = "realtime_source_fresh"
    case recentResult = "recent_result"
    case freePathSatisfied = "free_path_satisfied"
}

/// Structured scheduler log event for diagnostics (consumed by BB-19).
public struct FetchSchedulerLogEvent: Equatable {
    public enum Kind: String, Equatable {
        case requested, dispatched, skipped, completed, discardedStaleEpoch = "discarded_stale_epoch"
    }

    public let kind: Kind
    /// Reasons merged into this evaluation (sorted by raw value).
    public let reasons: [FetchRequestReason]
    public let skipReason: FetchSkipReason?
    /// Tokens available after this event.
    public let tokens: Int
    /// Remaining 429 cooldown in seconds, 0 when none.
    public let cooldownRemaining: TimeInterval
    /// Short non-secret result label for `completed` events.
    public let outcome: String?
    public let timestamp: Date
}

/// Result broadcast to every subscriber after a request completes for the current epoch.
public struct FetchSchedulerDelivery: Equatable {
    public let result: UsageFetchResult
    public let reasons: [FetchRequestReason]
    public let epoch: AccountEpoch
    public let receivedAt: Date
}
