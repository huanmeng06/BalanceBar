import Foundation

/// Identifies the source used to derive an account's stable identifier.
public enum AccountIdentitySource: String, Codable, Equatable, Hashable {
    /// The identifier came from the provider's account UUID.
    case accountUUID = "account_uuid"

    /// The normalized account email was used as a deterministic fallback.
    case emailFallback = "email_fallback"
}

/// Stable account metadata shared by quota sources, caches, and the merge engine.
public struct AccountIdentity: Codable, Equatable, Hashable {
    /// Short nested spelling for the identity-source type.
    public typealias Source = AccountIdentitySource

    /// The stable identifier used to partition observations and cached state.
    public let stableID: String

    /// The account email, when the provider exposed one.
    public let email: String?

    /// The provider's plan name, when known.
    public let plan: String?

    /// The method used to produce `stableID`.
    public let idSource: AccountIdentitySource

    /// Creates an account identity from a provider identifier or email fallback.
    public init(
        stableID: String,
        email: String? = nil,
        plan: String? = nil,
        idSource: AccountIdentitySource
    ) {
        self.stableID = stableID
        self.email = email
        self.plan = plan
        self.idSource = idSource
    }

    /// Creates an account identity using the alternate `source` label.
    public init(
        stableID: String,
        email: String? = nil,
        plan: String? = nil,
        source: AccountIdentitySource
    ) {
        self.init(stableID: stableID, email: email, plan: plan, idSource: source)
    }

    /// The source label retained for callers that use the shorter contract name.
    public var source: AccountIdentitySource { idSource }

    /// The plan label retained for callers that use the descriptive property name.
    public var planName: String? { plan }

    private enum CodingKeys: String, CodingKey {
        case stableID = "stable_id"
        case email
        case plan
        case idSource = "id_source"
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stableID = try container.decode(String.self, forKey: .stableID)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        idSource = try container.decodeIfPresent(AccountIdentitySource.self, forKey: .idSource)
            ?? container.decode(AccountIdentitySource.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stableID, forKey: .stableID)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encode(idSource, forKey: .idSource)
    }
}

/// Opaque, non-secret version information for the active credential.
public struct CredentialVersion: Codable, Equatable, Hashable {
    /// The caller-provided irreversible version value.
    public let value: String

    /// Creates a credential version from an opaque value.
    public init(_ value: String) {
        self.value = value
    }

    /// Creates a credential version using the labeled initializer form.
    public init(value: String) {
        self.value = value
    }

    /// Alias for code that treats the version as a raw value.
    public var rawValue: String { value }
}

/// Monotonic account-generation identifier used to invalidate stale results.
public struct AccountEpoch: Codable, Equatable, Hashable, Comparable {
    /// The numeric generation value.
    public let rawValue: UInt64

    /// The initial account generation.
    public static let initial = Self(rawValue: 0)

    /// Creates an account epoch from its numeric value.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Creates an account epoch from its numeric value.
    public init(_ rawValue: UInt64) {
        self.init(rawValue: rawValue)
    }

    /// Returns the next generation, saturating at the largest representable value.
    public var next: Self {
        Self(rawValue: rawValue == UInt64.max ? rawValue : rawValue + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Canonical quota-window categories shared by observations and display models.
public enum QuotaWindowKind: Codable, Equatable, Hashable, CustomStringConvertible {
    /// The rolling five-hour window.
    case fiveHour

    /// The rolling seven-day window.
    case sevenDay

    /// A provider-specific window that is not one of the two standard windows.
    case other

    /// The canonical Schema v1 name for this window category.
    public var rawValue: String {
        switch self {
        case .fiveHour: return "five_hour"
        case .sevenDay: return "seven_day"
        case .other: return "other"
        }
    }

    /// Creates a category from common HUD/Schema spellings.
    public init(rawValue: String) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "five_hour", "fivehour", "5h": self = .fiveHour
        case "seven_day", "sevenday", "7d": self = .sevenDay
        default: self = .other
        }
    }

    /// A human-readable description suitable for diagnostics.
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Trust grade attached to an observation from a quota source.
public enum QuotaTrust: String, Codable, Equatable, Hashable {
    /// A directly authenticated or otherwise authoritative observation.
    case a

    /// A corroborated or lower-confidence observation.
    case b
}

/// State shown for one quota window or for an aggregate display model.
public enum WindowState: String, Codable, Equatable, Hashable {
    /// No observation is available.
    case noData = "no_data"

    /// The service explicitly reported a zero-use window without a reset time.
    case notStarted = "not_started"

    /// The window has an active observation.
    case inProgress = "in_progress"

    /// The previous window passed its reset time and confirmation is pending.
    case resetPendingConfirmation = "reset_pending_confirmation"

    /// The last known observation is past its usable lifetime.
    case expired

    /// The source or merge path reported an error.
    case error

    /// Alias for the state-machine wording used by the merge-engine contract.
    public static var estimatedResetPendingConfirmation: Self { .resetPendingConfirmation }
}

/// A validated observation of one quota window.
public struct QuotaObservation: Equatable {
    /// The observed window category.
    public let window: QuotaWindowKind

    /// Percentage already used, constrained to 0...100.
    public let usedPercentage: Double

    /// Absolute reset time supplied by the source, when available.
    public let resetsAt: Date?

    /// Source observation time, when supplied by the source.
    public let observedAt: Date?

    /// Local receipt time used for freshness decisions.
    public let receivedAt: Date

    /// Stable source identifier such as `claude-hud` or `balancebar-mod`.
    public let source: String

    /// Trust grade assigned by the source adapter.
    public let trust: QuotaTrust

    /// Stable account identifier owning this observation.
    public let accountID: String

    /// Account generation captured when the observation was produced.
    public let epoch: AccountEpoch

    /// Creates an observation, returning `nil` for invalid percentages, dates, or identifiers.
    public init?(
        window: QuotaWindowKind,
        usedPercentage: Double,
        resetsAt: Date? = nil,
        observedAt: Date? = nil,
        receivedAt: Date,
        source: String,
        trust: QuotaTrust,
        accountID: String,
        epoch: AccountEpoch
    ) {
        guard usedPercentage.isFinite, (0...100).contains(usedPercentage),
              receivedAt.timeIntervalSince1970.isFinite,
              resetsAt?.timeIntervalSince1970.isFinite ?? true,
              observedAt?.timeIntervalSince1970.isFinite ?? true,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.window = window
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.receivedAt = receivedAt
        self.source = source
        self.trust = trust
        self.accountID = accountID
        self.epoch = epoch
    }

    /// Alias for code that calls the trust field a confidence level.
    public var trustLevel: QuotaTrust { trust }
}

/// Display-ready values for one quota window.
public struct QuotaWindowDisplay: Codable, Equatable {
    /// The window category represented by this display value.
    public let kind: QuotaWindowKind

    /// Percentage already used, or `nil` when the window has no data.
    public let usedPercentage: Double?

    /// Absolute reset time, when known.
    public let resetsAt: Date?

    /// Whether the displayed value was estimated rather than directly observed.
    public let isEstimated: Bool

    /// Current state for this window.
    public let state: WindowState

    /// Localization key for the hover explanation.
    public let hoverTextKey: String

    /// Creates a display value for one window.
    public init(
        kind: QuotaWindowKind,
        usedPercentage: Double?,
        resetsAt: Date? = nil,
        isEstimated: Bool,
        state: WindowState,
        hoverTextKey: String
    ) {
        self.kind = kind
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.isEstimated = isEstimated
        self.state = state
        self.hoverTextKey = hoverTextKey
    }

    /// Alias for callers that use “display value” terminology.
    public var displayValue: Double? { usedPercentage }
}

/// Aggregate display state exposed to UI and diagnostics consumers.
public struct QuotaDisplayModel: Codable, Equatable {
    /// Per-window display values in stable contract order.
    public let windows: [QuotaWindowDisplay]

    /// Whether any displayed value is estimated.
    public let isEstimated: Bool

    /// Aggregate state used by the status indicator.
    public let state: WindowState

    /// Localization key for the aggregate hover explanation.
    public let hoverTextKey: String

    /// Creates an aggregate display model.
    public init(
        windows: [QuotaWindowDisplay],
        isEstimated: Bool,
        state: WindowState,
        hoverTextKey: String
    ) {
        self.windows = windows
        self.isEstimated = isEstimated
        self.state = state
        self.hoverTextKey = hoverTextKey
    }

    /// Returns the display value for one window, if present.
    public func window(for kind: QuotaWindowKind) -> QuotaWindowDisplay? {
        windows.first { $0.kind == kind }
    }

    /// Alias for consumers that call the aggregate state a status.
    public var status: WindowState { state }
}
