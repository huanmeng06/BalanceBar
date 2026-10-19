import Foundation

/// Read-only account switch history (implemented by `ClaudeAccountIdentityProvider`).
public protocol AccountTimelineProviding {
    var timeline: [AccountTimelineEntry] { get }
    func timelineEntry(at date: Date) -> AccountTimelineEntry?
}

extension ClaudeAccountIdentityProvider: AccountTimelineProviding {}

/// Read-only record of whether the active CC Switch provider was Claude official direct.
public protocol ProviderTimelineProviding {
    /// `true` / `false` when known at `date`; `nil` when there is no record that early.
    func isOfficialDirect(at date: Date) -> Bool?
    /// Dates at which the provider changed.
    var switchDates: [Date] { get }
}

/// In-memory provider history fed by observed provider changes.
public final class ProviderTimeline: ProviderTimelineProviding {
    private let lock = NSLock()
    private var entries: [(switchedAt: Date, officialDirect: Bool)] = []

    public init() {}

    public func record(officialDirect: Bool, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        if entries.last?.officialDirect == officialDirect { return }
        entries.append((date, officialDirect))
        entries.sort { $0.switchedAt < $1.switchedAt }
    }

    public func isOfficialDirect(at date: Date) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return entries.last { $0.switchedAt <= date }?.officialDirect
    }

    public var switchDates: [Date] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.switchedAt)
    }
}

public enum UsageAttributionResult: Equatable {
    case attributed(accountID: String)
    case noAccount
    case providerNotOfficial
}

/// Decides which account, if any, a message counts toward.
///
/// A message counts only when it falls inside an interval where an account was active **and**
/// the provider was Claude official direct. The configuration directory is never consulted.
public struct UsageAttributor {
    private let accounts: AccountTimelineProviding
    private let providers: ProviderTimelineProviding

    public init(accounts: AccountTimelineProviding, providers: ProviderTimelineProviding) {
        self.accounts = accounts
        self.providers = providers
    }

    public func attribute(_ record: TranscriptUsageRecord) -> UsageAttributionResult {
        guard let identity = accounts.timelineEntry(at: record.timestamp)?.identity else { return .noAccount }
        guard providers.isOfficialDirect(at: record.timestamp) == true else { return .providerNotOfficial }
        return .attributed(accountID: identity.stableID)
    }

    /// Whether the account or provider changed in `(start, end]`.
    public func switchOccurred(from start: Date, to end: Date) -> Bool {
        accounts.timeline.contains { $0.switchedAt > start && $0.switchedAt <= end }
            || providers.switchDates.contains { $0 > start && $0 <= end }
    }
}
