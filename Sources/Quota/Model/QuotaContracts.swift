import Foundation

/// Centralized timing, validation, and request-budget values for quota modules.
public enum QuotaConstants {
    /// Minimum interval between automatically requested usage reads.
    public static let automaticRequestMinimumInterval: TimeInterval = 180

    /// Lower bound applied to server-request cooldowns.
    public static let minimumCooldown: TimeInterval = 15 * 60

    /// How long a real-time source remains fresh for request suppression.
    public static let realtimeSourceFreshness: TimeInterval = 120

    /// Maximum allowed difference for a grade-B observation, in percentage points.
    public static let gradeBTolerancePercentagePoints: Double = 2

    /// Maximum accepted serialized snapshot size.
    public static let snapshotMaximumSizeBytes = 64 * 1_024

    /// Window used to merge bursts of quota directory events into one notification.
    public static let directoryWatchCoalescingInterval: TimeInterval = 1

    /// Maximum bytes read from one file by a single incremental JSONL read.
    public static let incrementalReadMaximumBytes = 4 * 1_024 * 1_024

    /// Maximum complete lines returned by a single incremental JSONL read.
    public static let incrementalReadMaximumLines = 10_000

    /// Maximum remembered deduplication keys per incrementally read file.
    public static let incrementalReadMaximumDeduplicationKeys = 50_000

    /// Capacity of the scheduler's request token bucket.
    public static let requestTokenBucketCapacity = 3

    /// Refill interval for one request token.
    public static let requestTokenRefillInterval: TimeInterval = 3 * 60

    /// Tokens required by an automatic request.
    public static let automaticRequestTokenCost = 2

    /// Tokens required by a manually requested read.
    public static let manualRequestTokenCost = 1

    /// Time window used by a manual refresh eligibility check.
    public static let manualRefreshWindow: TimeInterval = 60

    /// Delay used to coalesce bursts of account-configuration file events.
    public static let accountChangeCoalescingInterval: TimeInterval = 0.5

    /// Refreshes issued after a task ends for API provider balances.
    public static let apiPostTaskRefreshCount = 4

    /// Refreshes issued after a task ends for official quota.
    public static let officialPostTaskRefreshCount = 2
}

/// Reason supplied when a caller asks the scheduler for a usage read.
public enum FetchRequestReason: String, Codable, Equatable, Hashable {
    /// Initial loading of the active account.
    case initial

    /// A regular automatic refresh.
    case scheduled

    /// A user-initiated refresh.
    case manual

    /// Confirmation requested after a quota reset deadline passed.
    case resetConfirmation = "reset_confirmation"

    /// Calibration requested by the estimator.
    case estimatedCalibration = "estimated_calibration"

    /// Refresh requested after activity on another client or device.
    case externalActivity = "external_activity"
}

/// Notification events that can be forwarded to the existing notification rules.
public enum QuotaNotificationEvent: Equatable {
    /// A new quota cycle was confirmed for a window.
    case resetConfirmed(window: QuotaWindowKind)
}

/// A source that emits normalized quota observations.
public protocol QuotaSource {
    /// Stable diagnostic identifier for this source adapter.
    var sourceID: String { get }

    /// Starts observation and delivers normalized values to the supplied handler.
    func start(receiving handler: @escaping (QuotaObservation) -> Void)

    /// Stops observation and releases source-owned resources.
    func stop()
}

/// Provides the active account identity and credential generation to quota modules.
public protocol AccountIdentityProviding {
    /// Current stable account identity, or `nil` when no account is available.
    var accountIdentity: AccountIdentity? { get }

    /// Current opaque credential version, or `nil` when credentials are unavailable.
    var credentialVersion: CredentialVersion? { get }

    /// Current account generation used to reject stale asynchronous results.
    var accountEpoch: AccountEpoch { get }
}

/// The single request boundary used by estimators, sources, and reset confirmation.
public protocol FetchScheduling {
    /// Requests a read; the scheduler decides whether budget and cooldown allow it.
    func requestFetch(reason: FetchRequestReason)
}

/// Owns the merge boundary from normalized observations to display state.
public protocol QuotaMerging {
    /// Merges one observation and returns the resulting aggregate display model.
    @discardableResult
    func merge(_ observation: QuotaObservation) -> QuotaDisplayModel
}

/// Receives typed quota events and adapts them to the app's notification rules.
public protocol QuotaNotificationSink {
    /// Publishes one quota event to the notification integration.
    func publish(_ event: QuotaNotificationEvent)
}

/// Validates bytes before a quota source accepts a snapshot file.
public protocol FileValidating {
    /// Validates serialized file data and throws when it violates the contract.
    func validate(data: Data) throws
}

public extension FileValidating {
    /// Unlabeled spelling for callers that pass the bytes as the only argument.
    func validate(_ data: Data) throws {
        try validate(data: data)
    }
}
