import Foundation

/// The signed-in Codex login as an account identity for the rollout-log source.
///
/// The identity comes from `~/.codex/auth.json` (through `OfficialQuotaCredentialReading`) and is
/// re-read at most once per `refreshInterval`, on the caller's queue; callers are background
/// queues, never the main thread. The epoch advances whenever the signed-in account changes.
final class CodexAccountIdentityProvider: AccountIdentityProviding {
    private let readProfile: () -> CodexAccountProfile?
    private let now: () -> Date
    private let refreshInterval: TimeInterval
    private let lock = NSLock()
    private var identity: AccountIdentity?
    private var epoch = AccountEpoch.initial
    private var lastRead: Date?
    private var loaded = false

    init(
        readProfile: @escaping () -> CodexAccountProfile?,
        refreshInterval: TimeInterval = 2,
        now: @escaping () -> Date = Date.init
    ) {
        self.readProfile = readProfile
        self.refreshInterval = refreshInterval
        self.now = now
    }

    var accountIdentity: AccountIdentity? {
        refreshIfNeeded()
        return lock.withLock { identity }
    }

    var credentialVersion: CredentialVersion? { nil }

    var accountEpoch: AccountEpoch {
        refreshIfNeeded()
        return lock.withLock { epoch }
    }

    private func refreshIfNeeded() {
        let date = now()
        let due = lock.withLock { () -> Bool in
            if let lastRead, date >= lastRead, date.timeIntervalSince(lastRead) < refreshInterval { return false }
            lastRead = date
            return true
        }
        guard due else { return }
        let profile = readProfile()
        let email = profile?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let next = email.flatMap { value -> AccountIdentity? in
            value.isEmpty ? nil : AccountIdentity(
                stableID: "codex:" + value, email: value, plan: profile?.planType, idSource: .emailFallback)
        }
        lock.withLock {
            if loaded, next?.stableID != identity?.stableID {
                epoch = AccountEpoch(rawValue: epoch.rawValue + 1)
            }
            loaded = true
            identity = next
        }
    }
}

/// Reads official Codex rate limits from the local rollout logs and keeps them in a merge engine.
///
/// The engine is the single owner of the log-derived windows: it ignores other accounts, orders
/// readings by event time and notices a passed reset time. `freshDisplay` tells the refresh
/// coordinator when those windows may stand in for a `wham/usage` request.
final class CodexLocalQuota {
    private let identity: CodexAccountIdentityProvider
    private let source: CodexRolloutSource
    private let stateURL: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var engine: QuotaMergeEngine?
    private var started = false

    init(
        identity: CodexAccountIdentityProvider,
        source: CodexRolloutSource,
        stateDirectory: URL,
        now: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        self.source = source
        stateURL = stateDirectory.appendingPathComponent("codex-quota-merge.json")
        self.now = now
    }

    deinit { source.stop() }

    /// Production wiring: Codex login from `auth.json`, rollout files under `$CODEX_HOME/sessions`.
    static func makeProduction(officialQuotaClient: OfficialQuotaClient) -> CodexLocalQuota {
        let identity = CodexAccountIdentityProvider(readProfile: { officialQuotaClient.codexAccountProfile() })
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "BalanceBar", isDirectory: true)
            .appendingPathComponent("Quota", isDirectory: true)
        return CodexLocalQuota(
            identity: identity, source: CodexRolloutSource(accountProvider: identity), stateDirectory: directory)
    }

    /// Builds the engine and starts the log source. Idempotent; call from a background queue
    /// because restoring the engine reads the account file and the saved merge state.
    func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        let restoring = RebasingMergeStore(
            base: QuotaMergeFileStore(url: stateURL),
            accountID: identity.accountIdentity?.stableID,
            epoch: identity.accountEpoch)
        // Reset confirmation is answered by the ordinary `wham/usage` read: a window past its reset
        // time disables the log shortcut, so the engine's own request has nowhere else to go.
        let engine = QuotaMergeEngine(scheduler: IgnoredFetchScheduler(), store: restoring, now: now)
        lock.withLock { self.engine = engine }
        syncAccount(engine)
        source.start(receiving: { [weak self] observation in self?.receive(observation) })
    }

    func stop() { source.stop() }

    /// Merged log windows when the newest logged event is fresh, belongs to `accountKey` (the lowercased
    /// login email) and no window is waiting for a reset confirmation; otherwise `nil`.
    func freshDisplay(accountKey: String?) -> QuotaDisplayModel? {
        guard let accountKey, !accountKey.isEmpty,
              let engine = lock.withLock({ self.engine }),
              source.hasFreshData(at: now()),
              identity.accountIdentity?.email == accountKey.lowercased() else { return nil }
        syncAccount(engine)
        let model = engine.refresh()
        guard model.windows.contains(where: { $0.usedPercentage != nil }),
              !model.windows.contains(where: { $0.state == .resetPendingConfirmation }) else { return nil }
        return model
    }

    private func receive(_ observation: QuotaObservation) {
        guard let engine = lock.withLock({ self.engine }) else { return }
        syncAccount(engine)
        engine.merge(observation)
    }

    private func syncAccount(_ engine: QuotaMergeEngine) {
        guard let account = identity.accountIdentity else { return }
        engine.accountDidChange(epoch: identity.accountEpoch, accountID: account.stableID)
    }
}

private struct IgnoredFetchScheduler: FetchScheduling {
    func requestFetch(reason: FetchRequestReason) {}
}

extension OfficialQuotaResponseParser.Output {
    /// Replaces the percentages and reset times of the 5-hour and 7-day windows with log-derived
    /// readings. Everything a log cannot carry (Luna reserve, other windows) is kept from the last real
    /// response, and `bankedReset` is the final value that response resolved to (it may have needed a
    /// separate credit-list read). Returns `nil` when no window could be updated.
    func overlaid(with display: QuotaDisplayModel, now: Date, bankedReset: CodexBankedReset?) -> Self? {
        var updated = false
        let merged = windows.map { window -> OfficialQuotaWindow in
            let kind: QuotaWindowKind
            switch window.kind {
            case .fiveHour: kind = .fiveHour
            case .sevenDay: kind = .sevenDay
            case .other: return window
            }
            guard let local = display.windows.first(where: { $0.kind == kind }),
                  let used = local.usedPercentage else { return window }
            updated = true
            let resetAt = (local.resetsAt ?? window.resetAt).flatMap { $0 > now ? $0 : nil }
            let reset = resetAt.flatMap {
                ResponseParsingSupport.resetDescription($0.timeIntervalSince1970, now: now)
            } ?? window.reset
            return OfficialQuotaWindow(
                kind: window.kind,
                remaining: max(0, min(100, 100 - used)),
                label: window.label,
                daysText: window.daysText,
                reset: reset,
                durationSeconds: window.durationSeconds,
                resetAt: resetAt)
        }
        guard updated else { return nil }
        return Self(windows: merged, lunaReserve: lunaReserve, bankedReset: bankedReset,
                    bankedResetNeedsCreditList: false)
    }
}
