import Foundation

/// Supplies deterministic quota data only to the explicitly named
/// demo bundles. Normal development and production bundles return nil and
/// continue to use the live official quota response.
enum DevelopmentLunaReserveDemo {
    enum Mode: String {
        case zero
        case unavailable
        case fiveHourExhausted = "five-hour-exhausted"
        case sevenDayExhausted = "seven-day-exhausted"
        case bothExhausted = "both-exhausted"
    }

    private static let infoPlistKey = "BalanceBarLunaReserveDemo"

    static func snapshot(
        providerName: String,
        date: Date = Date()
    ) -> Snapshot? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              bundleIdentifier.contains(".demo."),
              let rawMode = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
              let mode = Mode(rawValue: rawMode)
        else {
            return nil
        }
        return snapshot(mode: mode, providerName: providerName, date: date)
    }

    static func snapshot(
        mode: Mode,
        providerName: String,
        date: Date = Date()
    ) -> Snapshot {
        let fiveHourRemaining: Double
        let sevenDayRemaining: Double
        switch mode {
        case .fiveHourExhausted:
            fiveHourRemaining = 0
            sevenDayRemaining = 60
        case .sevenDayExhausted:
            fiveHourRemaining = 75
            sevenDayRemaining = 0
        case .bothExhausted:
            fiveHourRemaining = 0
            sevenDayRemaining = 0
        case .zero, .unavailable:
            fiveHourRemaining = 75
            sevenDayRemaining = 60
        }
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: fiveHourRemaining,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2h0m",
                durationSeconds: 5 * 3_600
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: sevenDayRemaining,
                label: tr(.keyResponseParsers7DayQuota),
                daysText: tr(.keyResponseParsers7Days),
                reset: "5d3h",
                durationSeconds: 7 * 86_400
            )
        ]
        let reserve: LunaReserveQuota
        switch mode {
        case .zero:
            reserve = LunaReserveQuota(
                status: .available,
                remaining: 0,
                reset: "1h30m"
            )
        case .unavailable:
            reserve = LunaReserveQuota(
                status: .unavailable,
                remaining: nil,
                reset: nil
            )
        case .fiveHourExhausted, .sevenDayExhausted, .bothExhausted:
            reserve = LunaReserveQuota(
                status: .available,
                remaining: 45,
                reset: "1h30m"
            )
        }
        return .official(
            providerName,
            windows[1].remaining,
            windows[1].label,
            windows[1].reset,
            date,
            windows: windows,
            lunaReserve: reserve
        )
    }
}

/// Supplies a deterministic banked-reset list only to the explicitly named
/// demo bundle. Normal development and production bundles return nil.
enum DevelopmentBankedResetDemo {
    enum Mode: String {
        case tenCards = "banked-reset-10"
        case zeroCards = "banked-reset-0"
        case confirmed = "banked-reset-confirmed"
        case countdown = "banked-reset-countdown"
    }

    static let cardCount = 10
    private static let infoPlistKey = "BalanceBarBankedResetDemo"
    private static let remainingOffsets: [TimeInterval] = [
        30 * 60,
        6 * 3_600,
        18 * 3_600,
        30 * 3_600,
        2 * 86_400,
        3 * 86_400,
        (4 * 86_400) + (12 * 3_600),
        6 * 86_400,
        8 * 86_400,
        10 * 86_400
    ]

    static func snapshot(
        providerName: String,
        date: Date = Date()
    ) -> Snapshot? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              bundleIdentifier.contains(".demo."),
              let rawMode = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
              let mode = Mode(rawValue: rawMode)
        else {
            return nil
        }
        return snapshot(mode: mode, providerName: providerName, date: date)
    }

    static func snapshot(
        mode: Mode,
        providerName: String,
        date: Date = Date()
    ) -> Snapshot {
        SwitchLog.write(
            "banked-reset demo snapshot requested; mode=\(mode.rawValue); provider=\(providerName)",
            level: .debug,
            category: "configuration"
        )
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2h0m",
                durationSeconds: 5 * 3_600
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota),
                daysText: tr(.keyResponseParsers7Days),
                reset: "5d3h",
                durationSeconds: 7 * 86_400
            )
        ]
        let cardList: [CodexBankedResetCard]
        switch mode {
        case .tenCards:
            cardList = cards(now: date)
        case .zeroCards:
            cardList = []
        case .confirmed, .countdown:
            cardList = Array(cards(now: date).prefix(2))
        }
        var forecast = CodexResetForecast.demo(updatedAt: date)
        if mode == .confirmed {
            forecast.officialSignal = CodexResetOfficialSignal(
                probability: .percent(80),
                targetAt: date.addingTimeInterval(3 * 3_600),
                publishedAt: date.addingTimeInterval(-3_600),
                episodeKey: "demo-confirmed"
            )
            forecast.officialResetObservation = .observed
        } else if mode == .countdown {
            // Keep a valid publish → deadline span at any launch time so the
            // demo always exercises the full-width countdown progress row.
            forecast.officialSignal = CodexResetOfficialSignal(
                probability: .percent(80),
                targetAt: nextLocalEightPM(after: date),
                publishedAt: date.addingTimeInterval(-3_600),
                episodeKey: "demo-countdown"
            )
        }
        let displayedProviderName = mode == .countdown
            ? "\(providerName) · DEMO 20:00"
            : providerName
        return .official(
            displayedProviderName,
            windows[1].remaining,
            windows[1].label,
            windows[1].reset,
            date,
            windows: windows,
            bankedReset: CodexBankedReset(cards: cardList),
            resetForecast: forecast
        )
    }

    /// Next 20:00 in the current local zone. Using the local calendar keeps the
    /// demo aligned with the user's wall clock; the menu still formats the
    /// instant in the configured display time zone.
    static func nextLocalEightPM(
        after date: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 20
        components.minute = 0
        components.second = 0
        guard let today = calendar.date(from: components) else {
            return date.addingTimeInterval(3 * 3_600)
        }
        if today > date { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
            ?? date.addingTimeInterval(23 * 3_600)
    }

    static func cards(now: Date) -> [CodexBankedResetCard] {
        remainingOffsets.enumerated().map { index, offset in
            let expiresAt = now.addingTimeInterval(offset)
            let remaining = CodexBankedResetFormatting.remaining(until: expiresAt, now: now)
            return CodexBankedResetCard(
                id: "demo-\(index + 1)",
                resetType: "codex_rate_limits",
                titleText: tr(.keyCodexBankedResetFullResetTitle),
                windowText: tr(.keyCodexBankedResetFullResetWindow),
                expiresAt: expiresAt,
                expiresText: CodexBankedResetFormatting.expiryText(
                    for: expiresAt,
                    relativeTo: now
                ),
                remainingText: remaining?.text,
                remainingIsWarning: remaining?.isWarning ?? false
            )
        }
    }
}

struct ProviderRefreshActions {
    let currentProvider: (AssistantClient) -> CCSwitchProvider?
    let isActiveClient: (AssistantClient) -> Bool
    let render: (Snapshot) -> Void
    let storeClientSnapshot: (AssistantClient, String, Snapshot) -> Void
    var storeClientSnapshotWithRevision: ((AssistantClient, String, String, Snapshot) -> Void)? = nil
    let quickSwitchSummaryChanged: (String) -> Void
    var notificationSnapshot: ((AssistantClient, String, Snapshot) -> Void)? = nil
    /// The latest request for these providers failed; their last notification
    /// samples are no longer current until a real refresh succeeds.
    var notificationSamplesInvalidated: ((AssistantClient, Set<String>) -> Void)? = nil
    /// The signed-in account (opaque identity) behind this client's official
    /// quota, reported on every observation so notifications never rely on
    /// this coordinator's resettable provider indices.
    var notificationAccountScopeChanged: ((AssistantClient, String?) -> Void)? = nil
    var quickSwitchSafetyChanged: ((CCSwitchQuickSwitchSafety) -> Void)? = nil
    var aggregationChanged: (([AggregatedProviderDisplay], Bool) -> Void)? = nil
    var ownedRender: ((String, Snapshot) -> Void)? = nil
}

/// Persists only the local observation state needed to survive menu rebuilds
/// and app restarts. The key is scoped by provider and account identity so a
/// different Codex account can never consume another account's evidence.
final class CodexResetObservationStore {
    private struct Entry: Codable {
        let episodeKey: String
        let observation: CodexResetObservation
    }

    private let defaults: UserDefaults
    private let keyPrefix = "BalanceBar.codexResetObservation."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(providerID: String, accountKey: String) -> (episodeKey: String, observation: CodexResetObservation)? {
        guard let data = defaults.data(forKey: key(providerID: providerID, accountKey: accountKey)),
              let entry = try? PropertyListDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return (entry.episodeKey, entry.observation)
    }

    func save(
        providerID: String,
        accountKey: String,
        episodeKey: String,
        observation: CodexResetObservation
    ) {
        guard let data = try? PropertyListEncoder().encode(
            Entry(episodeKey: episodeKey, observation: observation)
        ) else { return }
        defaults.set(data, forKey: key(providerID: providerID, accountKey: accountKey))
    }

    func remove(providerID: String, accountKey: String) {
        defaults.removeObject(forKey: key(providerID: providerID, accountKey: accountKey))
    }

    func loadQuotaEvidence(providerID: String, accountKey: String) -> CodexResetObservation? {
        guard let data = defaults.data(forKey: key(providerID: providerID, accountKey: accountKey) + ".quotaEvidence") else { return nil }
        return try? PropertyListDecoder().decode(CodexResetObservation.self, from: data)
    }

    func saveQuotaEvidence(providerID: String, accountKey: String, evidence: CodexResetObservation) {
        guard let data = try? PropertyListEncoder().encode(evidence) else { return }
        defaults.set(data, forKey: key(providerID: providerID, accountKey: accountKey) + ".quotaEvidence")
    }

    // Separate payload/key: never migrate, overwrite or reinterpret reset-event records.
    private struct PredictionWindow: Codable {
        let cycle: QuotaPredictionCycle
        var lastRemaining: Double
        var suppressed: Bool
    }
    private struct PredictionEntry: Codable {
        var windows: [PredictionWindow] = []
        var lastProcessedResetEventID: Date?
        var lastSampleAt: Date?
    }

    /// Called at the accepted quota-response boundary on the coordinator's serial queue.
    /// Missing/invalid individual windows retain prior state and yield no context;
    /// the other valid window remains independent.
    func updatePredictionContexts(providerID: String, accountKey: String,
                                  windows: [OfficialQuotaWindow], now: Date) -> [QuotaPredictionContext] {
        guard !accountKey.isEmpty, now.timeIntervalSince1970.isFinite else { return [] }
        let storageKey = key(providerID: providerID, accountKey: accountKey) + ".predictionCycles"
        var entry = defaults.data(forKey: storageKey).flatMap {
            try? PropertyListDecoder().decode(PredictionEntry.self, from: $0)
        } ?? PredictionEntry()
        if let last = entry.lastSampleAt, now < last { return [] }
        // The independent quota journal already applies the complete-snapshot reset rule.
        // Announcement state/request success is deliberately not a prerequisite here.
        if let evidence = loadQuotaEvidence(providerID: providerID, accountKey: accountKey),
           evidence.state == .observed, let event = evidence.detectedAt,
           event.timeIntervalSince1970.isFinite, event <= now,
           entry.lastProcessedResetEventID.map({ event > $0 }) ?? true {
            for index in entry.windows.indices { entry.windows[index].suppressed = true }
            entry.lastProcessedResetEventID = event
        }
        var contexts: [QuotaPredictionContext] = []
        for kind in [OfficialQuotaWindow.Kind.fiveHour, .sevenDay] {
            let matches = windows.filter { $0.kind == kind }
            guard matches.count == 1, let window = matches.first,
                  OfficialQuotaUsagePace.make(for: window, now: now) != nil,
                  let cycle = QuotaPredictionCycle(window: window) else { continue }
            let index: Int
            if let existing = entry.windows.firstIndex(where: { $0.cycle.kind == kind }) {
                index = existing
                if entry.windows[index].cycle != cycle {
                    // Old/out-of-order cycle metadata cannot resurrect an earlier basis.
                    guard cycle.resetAt > entry.windows[index].cycle.resetAt else { continue }
                    entry.windows[index] = PredictionWindow(cycle: cycle, lastRemaining: window.remaining, suppressed: false)
                } else {
                    if window.remaining > entry.windows[index].lastRemaining {
                        entry.windows[index].suppressed = true
                    }
                    entry.windows[index].lastRemaining = window.remaining
                }
            } else {
                index = entry.windows.count
                entry.windows.append(PredictionWindow(cycle: cycle, lastRemaining: window.remaining, suppressed: false))
            }
            contexts.append(QuotaPredictionContext(cycle: cycle,
                inferredCycleStart: entry.windows[index].suppressed ? nil : OfficialQuotaUsagePrediction.inferredCycleStart(for: window)))
        }
        entry.lastSampleAt = now
        if let data = try? PropertyListEncoder().encode(entry) { defaults.set(data, forKey: storageKey) }
        return contexts
    }

    private func key(providerID: String, accountKey: String) -> String {
        keyPrefix + providerID + "." + accountKey
    }
}

/// Owns standard Provider balance/quota requests, request cadence, quick
/// switch summaries, and Provider-balance fallback snapshots. It has no AppKit
/// page/window ownership; results leave through explicit value callbacks.
final class ProviderRefreshCoordinator {
    private enum QuickSwitchSummaryPayload: Equatable {
        case formatted(String)
        case officialWindows([OfficialQuotaWindow])
    }

    private let repository: CCSwitchRepository
    private let officialQuotaClient: OfficialQuotaClient
    private let balanceAPIClient: BalanceAPIClient
    private let balanceProgressStore: ProviderBalanceProgressStore
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let now: () -> Date
    private let refreshPreferences: AppPreferences?
    private var officialRefreshInterval: TimeInterval { refreshPreferences?.officialUsageRefreshInterval ?? 60 }
    private var lastOfficialSummaryFetch: [SummaryIdentity: Date] = [:]
    private var knownOfficialSummaryIDs: Set<SummaryIdentity> = []
    private var knownAPISummaryIDs: Set<SummaryIdentity> = []
    private var lastAPISummaryFetch: [SummaryIdentity: Date] = [:]
    private var loadedSummaryClients: Set<AssistantClient> = []
    /// Claude official quota path (identity → scheduler → merge engine →
    /// status and notifications). Every Claude official Provider shows the
    /// same account-wide data, so one pipeline serves them all.
    private let claudeQuota: ClaudeQuotaPipeline?
    /// The current standard Claude official Provider that receives pipeline updates.
    private var claudeStandardTarget: (providerID: String, providerName: String, revision: String)?
    private var claudeObservedEpoch: AccountEpoch?
    /// Last standard snapshot published for Claude, so identical state is not rendered twice.
    private var lastClaudePublication: (providerID: String, revision: String, snapshot: Snapshot)?
    private let actions: ProviderRefreshActions
    private let codexResetObservationStore: CodexResetObservationStore
    // Cadence timestamps are owned by `queue`; public entry points never read
    // or write them until their work reaches that serial boundary.
    private var lastBalanceFetch: Date?
    private var lastOfficialFetch: Date?
    private var quickSwitchSourceRevisions: [AssistantClient: [String: String]] = [:]
    private var lastStandardSourceKey: String?
    private var quickSwitchSummaryLock = NSLock()
    private struct SummaryIdentity: Hashable { let client: AssistantClient; let providerID: String }
    private var quickSwitchSummaryPayloads: [SummaryIdentity: QuickSwitchSummaryPayload] = [:]
    private var aggregationRetry: DispatchWorkItem?
    private var providerBalanceSnapshots = ProviderBalanceSnapshotCache()
    private var aggregationEntries: [AggregatedProviderEntry] = []
    private var aggregationDisplays: [AggregationDisplayIdentity: AggregatedProviderDisplay] = [:]
    private var aggregationAttempts: [AggregationDisplayIdentity: Date] = [:]
    private var aggregationRequests: [AggregationDisplayIdentity: UUID] = [:]
    private var aggregationPending: [AggregationDisplayIdentity] = []
    private var aggregationReader: CCSwitchAggregationRepository?
    private var aggregationBlocked = true
    private var quickSwitchSafety: CCSwitchQuickSwitchSafety = .blockedUntrusted
    private var lastQuickSwitchSafety: CCSwitchQuickSwitchSafety?
    private var standardOfficialRequests: [AssistantClient: OfficialQuotaRequestContext] = [:]
    private var aggregationOfficialRequests: [AggregationDisplayIdentity: OfficialQuotaRequestContext] = [:]
    private var lastAggregationPublication: (displays: [AggregatedProviderDisplay], blocked: Bool)?
    private let lifetime = OfficialResponseGeneration()
    private var standardPublicationEpoch = OfficialResponseGeneration()
    private struct CachedCodexResetForecast {
        let forecast: CodexResetForecast
        let fetchedAt: Date
    }
    // The public forecast is published with max-age=60. Avoid retaining an
    // obsolete announced deadline after upstream replaces or retracts it.
    static let codexResetForecastTTL: TimeInterval = 60
    // Failed/unavailable requests retry on the ordinary quota refresh cadence;
    // only successful forecasts receive the longer cache lifetime.
    static let codexResetForecastRetryInterval: TimeInterval = 60
    private var cachedCodexResetForecast: CachedCodexResetForecast?
    private var inFlightForecastCompletions: [(CodexResetForecast) -> Void] = []
    private var forecastRequestInFlight = false
    private var lastForecastAttempt: Date?
    // Response ownership is independent of quota values. The token is also read
    // on the main queue, so validity is synchronized instead of reading the map.
    private final class OfficialResponseGeneration {
        private let lock = NSLock()
        private var valid = true
        func invalidate() { lock.lock(); valid = false; lock.unlock() }
        func isCurrent() -> Bool { lock.lock(); defer { lock.unlock() }; return valid }
    }
    private var officialResponseGenerations: [String: OfficialResponseGeneration] = [:]
    private var codexQuotaEvidence: [String: CodexResetObservation] = [:]
    private var codexResetObservations: [String: (episodeKey: String, observation: CodexResetObservation)] = [:]

    init(
        repository: CCSwitchRepository,
        officialQuotaClient: OfficialQuotaClient,
        balanceAPIClient: BalanceAPIClient = BalanceAPIClient(),
        balanceProgressStore: ProviderBalanceProgressStore = ProviderBalanceProgressStore(),
        codexResetObservationStore: CodexResetObservationStore = CodexResetObservationStore(),
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.provider-refresh"),
        actions: ProviderRefreshActions,
        refreshPreferences: AppPreferences? = nil,
        claudeQuota: ClaudeQuotaPipeline? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.claudeQuota = claudeQuota
        self.repository = repository
        self.officialQuotaClient = officialQuotaClient
        self.balanceAPIClient = balanceAPIClient
        self.balanceProgressStore = balanceProgressStore
        self.codexResetObservationStore = codexResetObservationStore
        self.queue = queue
        self.now = now
        self.refreshPreferences = refreshPreferences
        self.actions = actions
        queue.setSpecific(key: queueKey, value: ())
        claudeQuota?.onUpdate = { [weak self] state in
            self?.performOnQueue { self?.applyClaudeState(state) }
        }
        claudeQuota?.onNotification = { [weak self] snapshot in
            self?.performOnQueue { self?.forwardClaudeNotification(snapshot) }
        }
    }

    func quickSwitchSummariesSnapshot(
        preferredQuotaWindow: OfficialQuotaWindowPreference,
        client: AssistantClient = .codex
    ) -> [String: String] {
        quickSwitchSummaryLock.lock()
        let payloads = quickSwitchSummaryPayloads
        quickSwitchSummaryLock.unlock()

        var summaries: [String: String] = [:]
        for (identity, payload) in payloads where identity.client == client {
            let providerID = identity.providerID
            switch payload {
            case .formatted(let text):
                summaries[providerID] = text
            case .officialWindows(let windows):
                switch OfficialQuotaWindowResolver.resolve(
                    windows,
                    preference: preferredQuotaWindow
                ) {
                case .selected(let window), .legacy(let window?):
                    summaries[providerID] = Self.formatOfficialQuotaSummary(window)
                case .legacy(nil), .unavailable:
                    break
                }
            }
        }
        return summaries
    }

    /// Called on the refresh owner queue before the ordinary single-provider path.
    @discardableResult
    func refreshAggregation(reader: CCSwitchAggregationRepository, force: Bool, forceAPIBalance: Bool? = nil) -> Bool {
        guard lifetime.isCurrent() else { return false }
        SwitchLog.write("aggregation refresh triggered; force=\(force)", level: .debug,
            category: "refresh.aggregation", throttleKey: "aggregation-trigger-\(force)", minimumInterval: 1)
        aggregationReader = reader
        let state = reader.load()
        quickSwitchSafety = reader.quickSwitchSafety()
        aggregationBlocked = quickSwitchSafety.isBlocked
        let entries: [AggregatedProviderEntry]
        switch state {
        case .untrusted:
            aggregationBlocked = quickSwitchSafety.isBlocked
            // A never-observed missing state file remains compatible with
            // legacy direct mode; only known/indicated aggregation retries.
            guard aggregationBlocked || !aggregationEntries.isEmpty else {
                publishAggregation()
                return false
            }
            for identity in aggregationDisplays.keys {
                aggregationDisplays[identity]?.reason = tr(.keyAggregationStale)
                if aggregationDisplays[identity]?.fetchedAt != nil { aggregationDisplays[identity]?.status = .stale }
            }
            publishAggregation()
            scheduleAggregationRetry(reader)
            return !aggregationEntries.isEmpty
        case .inactive: entries = []
        case .active(let active): entries = active
        }
        aggregationRetry?.cancel()
        aggregationRetry = nil
        aggregationBlocked = quickSwitchSafety.isBlocked
        let progressIdentities = entries.compactMap { entry in
            entry.source.query.map { ProviderBalanceProgressIdentity(client: .codex, providerID: entry.providerID,
                query: $0, providerName: entry.source.name) }
        }
        if progressIdentities.contains(where: balanceProgressStore.needsNameMigration),
           let sources = try? repository.loadSummarySourcesChecked(appType: "codex") {
            balanceProgressStore.prepareMigration(identities: sources.filter { !$0.isOfficial }.compactMap { source in
                source.query.map { ProviderBalanceProgressIdentity(client: .codex, providerID: source.id,
                    query: $0, providerName: source.name) }
            })
        }
        let identities = Set(entries.map(aggregationIdentity))
        if !entries.isEmpty {
            if let context = standardOfficialRequests.removeValue(forKey: .codex) { officialQuotaClient.cancelQuota(context: context) }
            standardPublicationEpoch.invalidate()
            standardPublicationEpoch = OfficialResponseGeneration()
        }
        let obsolete = aggregationDisplays.keys.filter { !identities.contains($0) }
        for identity in obsolete {
            aggregationRequests.removeValue(forKey: identity)
            if let display = aggregationDisplays.removeValue(forKey: identity) {
                cancelAggregationTransport(display)
            }
            aggregationAttempts.removeValue(forKey: identity)
        }
        aggregationPending.removeAll { !identities.contains($0) }
        aggregationEntries = entries
        for entry in entries {
            let identity = aggregationIdentity(entry)
            if var display = aggregationDisplays[identity] {
                display = AggregatedProviderDisplay(entry: entry, identity: identity, snapshot: display.snapshot,
                    account: display.account, status: display.status, reason: display.reason, fetchedAt: display.fetchedAt)
                aggregationDisplays[identity] = display
            } else {
                let profile = entry.source.officialAccessToken != nil
                    ? entry.source.officialAccount : officialQuotaClient.codexAccountProfile()
                aggregationDisplays[identity] = AggregatedProviderDisplay(entry: entry, identity: identity,
                    snapshot: .providerError(entry.source.name, reason: tr(.keyAggregationLoading), cachedBalance: nil),
                    account: entry.source.isOfficial ? OpenAIAccountPresentation.current(
                        activeClient: .codex, providerIsOfficial: true, email: profile?.email,
                        subscription: OpenAISubscriptionTier(planType: profile?.planType)) : nil,
                    status: .loading, reason: nil, fetchedAt: nil)
            }
            let interval = entry.source.isOfficial ? officialInterval(for: .codex)
                : TimeInterval(max(60, (entry.source.query?.intervalMinutes ?? 1) * 60))
            let due = aggregationAttempts[identity].map { now().timeIntervalSince($0) >= interval } ?? true
            let forceEntry = entry.source.isOfficial
                ? (force && refreshPreferences == nil) : (forceAPIBalance ?? force)
            if (forceEntry || due), aggregationRequests[identity] == nil, !aggregationPending.contains(identity) {
                aggregationPending.append(identity)
            } else {
                SwitchLog.write("aggregation refresh skipped; ttl=\(!due && !force); coalesced=\(aggregationRequests[identity] != nil || aggregationPending.contains(identity))",
                    level: .debug, category: "refresh.aggregation", throttleKey: "aggregation-skip", minimumInterval: 1)
            }
        }
        publishAggregation()
        drainAggregationRequests()
        return !entries.isEmpty
    }

    func stopAggregation() {
        performOnQueue { [weak self] in
            guard let self else { return }
            let displays = Array(self.aggregationDisplays.values)
            self.aggregationRequests.removeAll()
            self.aggregationPending.removeAll()
            self.aggregationEntries.removeAll()
            self.aggregationDisplays.removeAll()
            self.aggregationAttempts.removeAll()
            displays.forEach(self.cancelAggregationTransport)
            self.aggregationReader = nil
            self.aggregationRetry?.cancel()
            self.aggregationRetry = nil
        }
    }

    private func aggregationIdentity(_ entry: AggregatedProviderEntry) -> AggregationDisplayIdentity {
        let scope: String
        if entry.source.isOfficial {
            scope = entry.source.officialAccessToken.map {
                CodexRequestCredentials(accessToken: $0, accountKey: entry.source.officialAccount?.email?.lowercased()).requestScope
            } ?? officialQuotaClient.codexRequestCredentials().requestScope
        } else { scope = entry.source.configurationRevision }
        return AggregationDisplayIdentity(providerID: entry.providerID, accountScope: scope,
            configurationRevision: entry.source.configurationRevision)
    }

    private func cancelAggregationTransport(_ display: AggregatedProviderDisplay) {
        if let query = display.entry.source.query {
            balanceAPIClient.cancelBalance(query: query, client: .codex, providerID: display.identity.providerID)
        }
        if let context = aggregationOfficialRequests.removeValue(forKey: display.identity) {
            officialQuotaClient.cancelQuota(context: context)
        }
    }

    private func publishAggregation() {
        if lastQuickSwitchSafety != quickSwitchSafety {
            lastQuickSwitchSafety = quickSwitchSafety
            actions.quickSwitchSafetyChanged?(quickSwitchSafety)
        }
        let displays = aggregationEntries.compactMap { aggregationDisplays[aggregationIdentity($0)] }
        guard lastAggregationPublication?.displays != displays
            || lastAggregationPublication?.blocked != aggregationBlocked else { return }
        lastAggregationPublication = (displays, aggregationBlocked)
        SwitchLog.write("aggregation presentation published; providers=\(displays.count)", level: .debug,
            category: "refresh.aggregation", throttleKey: "aggregation-publication", minimumInterval: 1)
        actions.aggregationChanged?(displays, aggregationBlocked)
    }

    private func scheduleAggregationRetry(_ reader: CCSwitchAggregationRepository) {
        guard aggregationRetry == nil else { return }
        let retry = DispatchWorkItem { [weak self, weak reader] in
            guard let self, self.lifetime.isCurrent(), let reader, self.aggregationReader === reader else { return }
            self.aggregationRetry = nil
            _ = self.refreshAggregation(reader: reader, force: true)
        }
        aggregationRetry = retry
        queue.asyncAfter(deadline: .now() + 1, execute: retry)
    }

    private func aggregationRequestIsCurrent(_ identity: AggregationDisplayIdentity, request: UUID) -> Bool {
        guard aggregationRequests[identity] == request, let reader = aggregationReader else { return false }
        switch reader.load() {
        case .active(let entries) where entries.contains(where: { aggregationIdentity($0) == identity }): return true
        case .untrusted:
            // Keep trusted membership; release this attempt and retry after a
            // consistent read instead of publishing an unverified response.
            aggregationRequests.removeValue(forKey: identity)
            aggregationAttempts.removeValue(forKey: identity)
            if let display = aggregationDisplays[identity] { cancelAggregationTransport(display) }
            _ = refreshAggregation(reader: reader, force: false)
            return false
        default:
            aggregationRequests.removeValue(forKey: identity)
            _ = refreshAggregation(reader: reader, force: false)
            return false
        }
    }

    private func drainAggregationRequests() {
        while aggregationRequests.count < 2, !aggregationPending.isEmpty {
            let identity = aggregationPending.removeFirst()
            guard var display = aggregationDisplays[identity] else { continue }
            let request = UUID()
            aggregationRequests[identity] = request
            aggregationAttempts[identity] = now()
            SwitchLog.write("aggregation request dispatched; in_flight=\(aggregationRequests.count); pending=\(aggregationPending.count)",
                level: .debug, category: "refresh.aggregation")
            display.status = .loading
            let source = display.entry.source
            if source.isOfficial {
                let credentials = source.officialAccessToken.map {
                    CodexRequestCredentials(accessToken: $0, accountKey: source.officialAccount?.email?.lowercased())
                } ?? officialQuotaClient.codexRequestCredentials()
                aggregationOfficialRequests[identity] = OfficialQuotaRequestContext(client: .codex,
                    providerID: source.id, storedAccessToken: source.officialAccessToken, credentials: credentials)
            }
            aggregationDisplays[identity] = display
            publishAggregation()
            let isValid = { [weak self] in self?.aggregationRequestIsCurrent(identity, request: request) == true }
            let finish: (Snapshot) -> Void = { [weak self] snapshot in
                guard let self else { return }
                self.performOnQueue {
                    guard isValid(), var current = self.aggregationDisplays[identity] else { return }
                    self.aggregationRequests.removeValue(forKey: identity)
                    self.aggregationOfficialRequests.removeValue(forKey: identity)
                    if snapshot.kind == .error {
                        current.reason = snapshot.message
                        current.status = current.fetchedAt == nil ? .error : .stale
                        if current.fetchedAt == nil { current.snapshot = snapshot }
                    } else {
                        current.snapshot = snapshot
                        current.status = .fresh
                        current.reason = nil
                        current.fetchedAt = snapshot.date ?? self.now()
                        self.actions.notificationSnapshot?(.codex, identity.providerID, snapshot)
                    }
                    self.aggregationDisplays[identity] = current
                    self.publishAggregation()
                    self.drainAggregationRequests()
                }
            }
            if source.isOfficial {
                fetchOfficialQuota(providerID: source.id, providerName: source.name, client: .codex,
                    source: source, requestContext: aggregationOfficialRequests[identity],
                    configurationRevision: source.configurationRevision, isValid: isValid, completion: finish)
            } else if let query = source.query {
                fetchBalance(providerID: source.id, providerName: source.name, query: query, client: .codex,
                    isValid: isValid, onDiscard: { [weak self] in
                        guard let self, self.aggregationRequests[identity] == request else { return }
                        self.aggregationRequests.removeValue(forKey: identity)
                        self.drainAggregationRequests()
                    }, completion: finish)
            } else {
                aggregationRequests.removeValue(forKey: identity)
                display.snapshot = .providerError(source.name, reason: tr(.keyAggregationUnavailable), cachedBalance: nil)
                display.status = .unavailable
                display.reason = tr(.keyAggregationUnavailable)
                aggregationDisplays[identity] = display
                publishAggregation()
            }
        }
    }

    func resetCadence() {
        performOnQueue { [weak self] in
            guard let self else { return }
            self.lastStandardSourceKey = nil
            self.lastBalanceFetch = nil
            self.lastOfficialFetch = nil
            self.lastAPISummaryFetch = [:]
            self.lastClaudePublication = nil
            self.knownOfficialSummaryIDs.removeAll()
            self.knownAPISummaryIDs.removeAll()
            self.loadedSummaryClients.removeAll()
            self.lastOfficialSummaryFetch = [:]
            self.quickSwitchSourceRevisions = [:]
        }
    }

    /// Ends this owner's lifetime before an injected transport or repository is
    /// destroyed. Work already running finishes; queued/late work cannot launch
    /// requests or publish after this synchronous serial boundary returns.
    /// The transport owner remains responsible for cancelling/invalidation.
    func stop() {
        let finish = {
            self.lifetime.invalidate()
            self.aggregationRetry?.cancel()
            self.aggregationRetry = nil
            self.aggregationPending = []
            self.standardPublicationEpoch.invalidate()
            self.officialResponseGenerations.values.forEach { $0.invalidate() }
            self.claudeQuota?.onUpdate = nil
            self.claudeQuota?.onNotification = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { finish() }
        else { queue.sync(execute: finish) }
    }

    func performAsync(_ work: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self, self.lifetime.isCurrent() else { return }
            work()
        }
    }

    func refreshStandardProvider(
        current: CCSwitchProvider,
        client: AssistantClient,
        forceBalance: Bool,
        switched: Bool,
        userInitiated: Bool = false
    ) {
        performOnQueue { [weak self] in
            self?.refreshStandardProviderOnQueue(
                current: current,
                client: client,
                forceBalance: forceBalance,
                switched: switched,
                userInitiated: userInitiated
            )
        }
    }

    private func refreshStandardProviderOnQueue(
        current: CCSwitchProvider,
        client: AssistantClient,
        forceBalance: Bool,
        switched: Bool,
        userInitiated: Bool = false
    ) {
        let sourceKey = "\(client.appType)|\(current.id)|\(current.configurationRevision)"
        let sourceChanged = lastStandardSourceKey != sourceKey
        guard let query = current.query else {
            guard current.isOfficial, client == .codex || client == .claude else {
                if current.isOfficial {
                    return
                }
                let failure = current.queryFailure ?? .unknown
                let reason = failure.userVisibleReason(
                    language: AppLanguage.resolved
                )
                renderBalanceError(
                    providerID: current.id,
                    providerName: current.name,
                    reason: reason,
                    client: client,
                    configurationRevision: current.configurationRevision
                )
                return
            }
            if client == .claude {
                refreshClaudeStandard(current: current, sourceKey: sourceKey, sourceChanged: sourceChanged,
                    userInitiated: userInitiated)
                return
            }
            let currentDate = now()
            let due = lastOfficialFetch.map { currentDate.timeIntervalSince($0) >= officialInterval(for: client) } ?? true
            let shouldRefresh = refreshPreferences != nil ? (sourceChanged || due)
                : (forceBalance || switched || sourceChanged || due)
            guard shouldRefresh else { return }
            if standardIdentityChanged(from: lastStandardSourceKey, client: client, provider: current) != nil,
               let previous = standardOfficialRequests[client] {
                officialQuotaClient.cancelQuota(context: previous)
            }
            lastStandardSourceKey = sourceKey
            let revision = current.configurationRevision
            fetchOfficialQuota(
                providerID: current.id,
                providerName: current.name,
                client: client,
                configurationRevision: revision,
                isValid: { [weak self] in self?.standardRequestIsCurrent(client: client, providerID: current.id, revision: revision) == true }
            )
            lastOfficialFetch = currentDate
            return
        }

        let interval = TimeInterval(max(query.intervalMinutes, 1) * 60)
        let currentDate = now()
        let due = lastBalanceFetch.map { currentDate.timeIntervalSince($0) >= interval } ?? true
        guard forceBalance || switched || sourceChanged || due else { return }
        if let previousID = standardIdentityChanged(from: lastStandardSourceKey, client: client, provider: current) {
            balanceAPIClient.cancelBalance(client: client, providerID: previousID)
        }
        lastStandardSourceKey = sourceKey
        lastBalanceFetch = currentDate
        let revision = current.configurationRevision
        fetchBalance(
            providerID: current.id,
            providerName: current.name,
            query: query,
            client: client,
            configurationRevision: revision,
            isValid: { [weak self] in self?.standardRequestIsCurrent(client: client, providerID: current.id, revision: revision) == true }
        )
    }

    func prefetchCurrentBalance(for client: AssistantClient) {
        queue.async { [weak self] in
            guard let self, self.lifetime.isCurrent(), let current = self.repository.loadCurrent(appType: client.appType) else { return }
            let revision = current.configurationRevision
            let isValid = { [weak self] in self?.standardRequestIsCurrent(client: client, providerID: current.id, revision: revision) == true }
            if let query = current.query {
                self.fetchBalance(providerID: current.id, providerName: current.name, query: query, client: client,
                    configurationRevision: revision, isValid: isValid)
            } else if current.isOfficial, client == .claude {
                self.claudeStandardTarget = (current.id, current.name, revision)
                self.claudeQuota?.start()
                self.claudeQuota?.setDemand(true)
                self.claudeQuota?.requestFetch(reason: .initial)
                if let state = self.claudeQuota?.latestState { self.applyClaudeState(state) }
            } else if current.isOfficial, client == .codex {
                self.fetchOfficialQuota(providerID: current.id, providerName: current.name, client: client,
                    configurationRevision: revision, isValid: isValid)
            }
        }
    }

    func refreshQuickSwitchSummaries(
        force: Bool,
        for requestedClient: AssistantClient? = nil,
        providerIDs: Set<String>? = nil,
        configurationChanged: Bool = false
    ) {
        let client = requestedClient ?? .codex
        queue.async { [weak self] in
            guard let self, self.lifetime.isCurrent() else { return }
            let currentDate = self.now()
            let initialLoad = !self.loadedSummaryClients.contains(client)
            // Aggregation members follow refreshAggregation's own cadence, so
            // they must not make every timer poll reload provider configurations.
            let aggregatedIDs: Set<String> = client == .codex ? Set(self.aggregationEntries.map(\.providerID)) : []
            let apiDue = initialLoad || self.knownAPISummaryIDs.contains { identity in
                guard identity.client == client else { return false }
                if let providerIDs, !providerIDs.contains(identity.providerID) { return false }
                guard !aggregatedIDs.contains(identity.providerID) else { return false }
                return self.lastAPISummaryFetch[identity].map { currentDate.timeIntervalSince($0) >= 60 } ?? true
            }
            SwitchLog.write("quick-switch refresh triggered; force=\(force); api_ttl_due=\(apiDue); configuration_event=\(configurationChanged)", level: .debug,
                category: "refresh.summary", throttleKey: "summary-trigger-\(force)", minimumInterval: 1)
            let knownOfficialDue = client == .claude ? false : self.knownOfficialSummaryIDs.contains { identity in
                guard identity.client == client else { return false }
                if let providerIDs, !providerIDs.contains(identity.providerID) { return false }
                guard !aggregatedIDs.contains(identity.providerID) else { return false }
                return self.lastOfficialSummaryFetch[identity].map {
                    currentDate.timeIntervalSince($0) >= self.officialInterval(for: client)
                } ?? true
            }
            guard force || configurationChanged || initialLoad || apiDue || knownOfficialDue else { return }
            guard let sources = try? self.repository.loadSummarySourcesChecked(appType: client.appType) else { return }
            self.loadedSummaryClients.insert(client)
            let currentOfficialIDs = Set(sources.filter(\.isOfficial).map { SummaryIdentity(client: client, providerID: $0.id) })
            let currentAPIIDs = Set(sources.filter { !$0.isOfficial }.map { SummaryIdentity(client: client, providerID: $0.id) })
            self.knownOfficialSummaryIDs = self.knownOfficialSummaryIDs.filter { $0.client != client }
                .union(currentOfficialIDs)
            self.knownAPISummaryIDs = self.knownAPISummaryIDs.filter { $0.client != client }
                .union(currentAPIIDs)
            self.lastOfficialSummaryFetch = self.lastOfficialSummaryFetch.filter { $0.key.client != client || currentOfficialIDs.contains($0.key) }
            self.lastAPISummaryFetch = self.lastAPISummaryFetch.filter { $0.key.client != client || currentAPIIDs.contains($0.key) }
            let previousRevisions = self.quickSwitchSourceRevisions[client] ?? [:]
            self.quickSwitchSourceRevisions[client] = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.configurationRevision) })
            self.invalidateStaleQuickSwitchSummaries(client: client, sources: sources, previousRevisions: previousRevisions)
            var claudeFetchReason: FetchRequestReason?
            let aggregationIDs: Set<String>
            if client == .codex, let reader = self.aggregationReader, case .active(let entries) = reader.load() {
                _ = self.refreshAggregation(reader: reader, force: force && self.refreshPreferences == nil)
                aggregationIDs = Set(entries.map(\.providerID))
            } else { aggregationIDs = [] }
            self.balanceProgressStore.prepareMigration(identities: sources.compactMap { source in
                source.query.map { ProviderBalanceProgressIdentity(client: client, providerID: source.id, query: $0, providerName: source.name) }
            })
            for source in sources {
                if aggregationIDs.contains(source.id) { continue }
                if let providerIDs, !providerIDs.contains(source.id) { continue }
                if source.isOfficial, client == .claude {
                    // One account-wide read serves every Claude official Provider; the
                    // scheduler decides whether it is sent. Results fan out in applyClaudeState.
                    guard force || initialLoad || configurationChanged || previousRevisions[source.id] != source.configurationRevision else { continue }
                    claudeFetchReason = force ? .manual : .initial
                    continue
                }
                if source.isOfficial {
                    guard client == .codex else { continue }
                    let identity = SummaryIdentity(client: client, providerID: source.id)
                    let officialDue = self.lastOfficialSummaryFetch[identity].map {
                        currentDate.timeIntervalSince($0) >= self.officialInterval(for: client)
                    } ?? true
                    guard force || officialDue || configurationChanged || previousRevisions[source.id] != source.configurationRevision else { continue }
                    // Manual refresh rereads configuration and API balances, but
                    // official quota requests always honor the selected interval.
                    if self.refreshPreferences != nil,
                       previousRevisions[source.id] == source.configurationRevision,
                       let previous = self.lastOfficialSummaryFetch[identity],
                       currentDate.timeIntervalSince(previous) < self.officialInterval(for: client) { continue }
                    let credentials: CodexRequestCredentials? = source.officialAccessToken.map {
                        CodexRequestCredentials(accessToken: $0, accountKey: nil)
                    } ?? self.officialQuotaClient.codexRequestCredentials()
                    let context = OfficialQuotaRequestContext(client: client, providerID: source.id,
                        storedAccessToken: source.officialAccessToken, credentials: credentials)
                    self.officialQuotaClient.fetchQuota(context: context) { [weak self] result in
                        guard let self else { return }
                        self.performOnQueue {
                            // Each provider's configuration revision is checked and the
                            // account is verified against the credential store.
                            guard let currentSource = self.currentQuickSwitchSource(
                                client: client, providerID: source.id, revision: source.configurationRevision
                            ), currentSource.isOfficial,
                                  currentSource.officialAccessToken == source.officialAccessToken,
                                  self.officialCredentialsAreCurrent(client: client, storedAccessToken: context.storedAccessToken,
                                      credentials: credentials) else { return }
                            guard case .success(let response) = result else {
                                self.officialSampleUnavailable(client: client, providerID: source.id)
                                if previousRevisions[source.id] != source.configurationRevision {
                                    self.removeQuickSwitchSummary(providerID: source.id, client: client)
                                }
                                return
                            }
                            let predictionAccountKey = credentials?.accountKey
                            let predictionContexts = predictionAccountKey.map {
                                self.recordCodexQuotaEvidence(providerID: source.id, accountKey: $0,
                                    windows: response.output.windows, timestamp: self.now())
                            } ?? []
                            self.updateQuickSwitchSummary(
                                providerID: source.id,
                                client: client,
                                payload: .officialWindows(response.output.windows)
                            )
                            var sample = Snapshot.official(
                                source.name,
                                response.output.remaining,
                                response.output.label,
                                response.output.reset,
                                response.fetchedAt,
                                windows: response.output.windows,
                                lunaReserve: response.output.lunaReserve,
                                quotaPredictionContexts: predictionContexts,
                                quotaPredictionAccountKey: predictionAccountKey
                            )
                            self.actions.notificationSnapshot?(client, source.id, sample)
                        }
                    }
                    self.lastOfficialSummaryFetch[identity] = currentDate
                    continue
                }
                let apiIdentity = SummaryIdentity(client: client, providerID: source.id)
                let apiProviderDue = self.lastAPISummaryFetch[apiIdentity].map {
                    currentDate.timeIntervalSince($0) >= 60
                } ?? true
                guard force || apiProviderDue || previousRevisions[source.id] != source.configurationRevision else { continue }
                guard let query = source.query else {
                    self.lastAPISummaryFetch[apiIdentity] = currentDate
                    continue
                }
                let sampleSequence = self.balanceProgressStore.beginSample()
                self.balanceAPIClient.fetchBalance(
                    query: query,
                    client: client,
                    providerID: source.id
                ) { [weak self] result in
                    guard let self else { return }
                    self.performOnQueue {
                        guard self.currentQuickSwitchSource(
                            client: client, providerID: source.id, revision: source.configurationRevision
                        ) != nil else { return }
                        guard case .success(let response) = result else {
                            self.officialSampleUnavailable(client: client, providerID: source.id)
                            if previousRevisions[source.id] != source.configurationRevision {
                                self.removeQuickSwitchSummary(providerID: source.id, client: client)
                            }
                            return
                        }
                        let identity = ProviderBalanceProgressIdentity(
                            client: client,
                            providerID: source.id,
                            query: query, providerName: source.name
                        )
                        guard case .success(let observation) = self.balanceProgressStore.observe(
                            amount: response.output.amount, unit: response.output.unit,
                            identity: identity, sampleSequence: sampleSequence, observedAt: self.now()
                        ), observation.accepted else { return }
                        self.actions.notificationSnapshot?(
                            client,
                            source.id,
                            .balance(
                                source.name,
                                observation.amount,
                                observation.unit,
                                query.websiteURL,
                                observation.observedAt,
                                progressPercentage: observation.displayProgress, recharge: observation.recharge,
                                progressContext: observation.progressContext
                            )
                        )
                        self.updateQuickSwitchSummary(
                            providerID: source.id,
                            client: client,
                            payload: .formatted(Self.formatBalanceSummary(observation.amount, unit: observation.unit))
                        )
                    }
                }
                self.lastAPISummaryFetch[apiIdentity] = currentDate
            }
            if client == .claude, let claudeQuota = self.claudeQuota {
                claudeQuota.start()
                claudeQuota.setDemand(true)
                if let reason = claudeFetchReason { claudeQuota.requestFetch(reason: reason) }
                // A Provider added or edited since the last read shows the account's
                // current data at once instead of waiting for the next request.
                if let state = claudeQuota.latestState { self.applyClaudeSummaries(state) }
            }
        }
    }

    private func performOnQueue(_ work: @escaping () -> Void) {
        // Refresh can be requested from another coordinator's queue. Avoid a
        // second hop when already on the owner queue so FIFO behavior stays
        // identical for the existing composition-root refresh path.
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            if lifetime.isCurrent() { work() }
        } else {
            queue.async { [weak self] in
                guard let self, self.lifetime.isCurrent() else { return }
                work()
            }
        }
    }

    private func invalidateStaleQuickSwitchSummaries(
        client: AssistantClient,
        sources: [ProviderSummarySource],
        previousRevisions: [String: String]
    ) {
        let current = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.configurationRevision) })
        let deleted = Set(previousRevisions.keys.filter { current[$0] == nil })
        quickSwitchSummaryLock.lock()
        let missing = quickSwitchSummaryPayloads.keys.compactMap {
            $0.client == client && current[$0.providerID] == nil ? $0.providerID : nil
        }
        quickSwitchSummaryLock.unlock()
        deleted.union(missing).forEach { removeQuickSwitchSummary(providerID: $0, client: client) }
        for source in sources where previousRevisions[source.id].map({ $0 != source.configurationRevision }) == true {
            removeQuickSwitchSummary(providerID: source.id, client: client)
        }
    }

    private func removeQuickSwitchSummary(providerID: String, client: AssistantClient, notify: Bool = true) {
        let identity = SummaryIdentity(client: client, providerID: providerID)
        quickSwitchSummaryLock.lock()
        let existed = quickSwitchSummaryPayloads.removeValue(forKey: identity) != nil
        quickSwitchSummaryLock.unlock()
        if existed, notify { actions.quickSwitchSummaryChanged(providerID) }
    }

    private func standardRequestIsCurrent(client: AssistantClient, providerID: String, revision: String) -> Bool {
        guard let current = repository.loadCurrent(appType: client.appType) else { return false }
        return current.id == providerID && current.configurationRevision == revision
    }

    private func configurationIsCurrent(client: AssistantClient, providerID: String, revision: String) -> Bool {
        repository.configurationRevision(appType: client.appType, providerID: providerID) == revision
    }

    /// Re-reads only this provider's row: many summary responses can complete
    /// together, and each must not reparse the whole provider list.
    private func currentQuickSwitchSource(client: AssistantClient, providerID: String, revision: String) -> ProviderSummarySource? {
        guard quickSwitchSourceRevisions[client]?[providerID] == revision,
              let source = try? repository.loadSummarySourcesChecked(appType: client.appType, providerIDs: [providerID])
                .first(where: { $0.id == providerID }),
              source.configurationRevision == revision else { return nil }
        return source
    }

    /// Returns the previous Provider ID when client/id/revision actually changed.
    /// `resetCadence()` clears the last source key; that is not an identity change.
    @discardableResult
    private func standardIdentityChanged(
        from previousKey: String?,
        client: AssistantClient,
        provider: CCSwitchProvider
    ) -> String? {
        guard let previousKey else { return nil }
        let parts = previousKey.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let previousID = String(parts[1])
        let previousRevision = String(parts[2])
        guard parts[0] != client.appType
                || previousID != provider.id
                || previousRevision != provider.configurationRevision else {
            return nil
        }
        return previousID
    }

    private func updateQuickSwitchSummary(
        providerID: String,
        client: AssistantClient,
        payload: QuickSwitchSummaryPayload
    ) {
        let identity = SummaryIdentity(client: client, providerID: providerID)
        quickSwitchSummaryLock.lock()
        let previous = quickSwitchSummaryPayloads[identity]
        guard previous != payload else {
            quickSwitchSummaryLock.unlock()
            return
        }
        quickSwitchSummaryPayloads[identity] = payload
        quickSwitchSummaryLock.unlock()
        actions.quickSwitchSummaryChanged(providerID)
    }

    private func fetchBalance(
        providerID: String,
        providerName: String,
        query: BalanceQuery,
        client: AssistantClient,
        configurationRevision: String = "",
        isValid: @escaping () -> Bool = { true },
        onDiscard: (() -> Void)? = nil,
        completion: ((Snapshot) -> Void)? = nil
    ) {
        func fail(providerID: String, providerName: String, reason: String, client: AssistantClient) {
            officialSampleUnavailable(client: client, providerID: providerID)
            if let completion { completion(.providerError(providerName, reason: reason, cachedBalance: nil)) }
            else {
                renderBalanceError(
                    providerID: providerID,
                    providerName: providerName,
                    reason: reason,
                    client: client,
                    configurationRevision: configurationRevision
                )
            }
        }
        let identity = ProviderBalanceProgressIdentity(client: client, providerID: providerID, query: query, providerName: providerName)
        if balanceProgressStore.needsNameMigration(identity) {
            // Include every same-name peer before deciding whether old query
            // records agree. A partial list could adopt a conflicting baseline.
            if let sources = try? repository.loadSummarySourcesChecked(appType: client.appType) {
                balanceProgressStore.prepareMigration(identities: sources.filter { !$0.isOfficial }.compactMap { source in
                    source.query.map { ProviderBalanceProgressIdentity(client: client, providerID: source.id,
                        query: $0, providerName: source.name) }
                })
            }
        } else if client != .codex { balanceProgressStore.prepareMigration(identities: [identity]) }
        let sampleSequence = balanceProgressStore.beginSample()
        guard balanceAPIClient.fetchBalance(
            query: query,
            client: client,
            providerID: providerID,
            completion: { [weak self] result in
            guard let self else { return }
            self.performOnQueue {
                let requestIsCurrent = isValid()
                let configurationIsCurrent = requestIsCurrent || self.configurationIsCurrent(
                    client: client, providerID: providerID, revision: configurationRevision
                )
                let selectedMovedAway: Bool
                if !configurationRevision.isEmpty,
                   configurationIsCurrent,
                   let selected = self.repository.loadCurrent(appType: client.appType) {
                    selectedMovedAway = selected.id != providerID
                } else {
                    selectedMovedAway = false
                }
                guard requestIsCurrent || selectedMovedAway else { return }
                switch result {
                case .success(let response):
                    let progressResult = self.balanceProgressStore.observe(
                        amount: response.output.amount, unit: response.output.unit,
                        identity: identity, sampleSequence: sampleSequence, observedAt: self.now())
                    guard case .success(let observation) = progressResult else {
                        if requestIsCurrent, case .failure(let error) = progressResult {
                            fail(providerID: providerID, providerName: providerName,
                                reason: error.userVisibleReason(language: AppLanguage.resolved), client: client)
                        }
                        return
                    }
                    guard observation.accepted else { onDiscard?(); return }
                    guard configurationIsCurrent else { return }
                    self.updateQuickSwitchSummary(
                        providerID: providerID,
                        client: client,
                        payload: .formatted(Self.formatBalanceSummary(observation.amount, unit: observation.unit))
                    )
                    let balanceSnapshot = Snapshot.balance(
                        providerName,
                        observation.amount,
                        observation.unit,
                        query.websiteURL,
                        observation.observedAt,
                        progressPercentage: observation.displayProgress,
                        recharge: observation.recharge,
                        progressContext: observation.progressContext
                    )
                    guard requestIsCurrent else { return }
                    if let completion { completion(balanceSnapshot) }
                    else {
                        self.renderForCurrentProvider(
                            balanceSnapshot,
                            providerID: providerID,
                            client: client,
                            configurationRevision: configurationRevision
                        )
                    }
                case .failure(.nonHTTPS):
                    if requestIsCurrent {
                        fail(providerID: providerID, providerName: providerName, reason: tr(.keyProviderRefreshCoordinatorTheBalanceEndpointIsNotHttps), client: client)
                    }
                case .failure(.transport(let error)):
                    if requestIsCurrent {
                        fail(providerID: providerID, providerName: providerName, reason: Self.localizedBalanceNetworkErrorReason(error, language: AppLanguage.resolved), client: client)
                    }
                case .failure(.httpStatus):
                    if requestIsCurrent {
                        fail(providerID: providerID, providerName: providerName, reason: tr(.keyProviderRefreshCoordinatorTheBalanceEndpointReturnedAnError), client: client)
                    }
                case .failure(.unsupportedFormat):
                    if requestIsCurrent {
                        fail(providerID: providerID, providerName: providerName, reason: tr(.keyProviderRefreshCoordinatorUnrecognizedBalanceFormat), client: client)
                    }
                case .failure(.invalidJSON):
                    if requestIsCurrent {
                        fail(providerID: providerID, providerName: providerName, reason: tr(.keyProviderRefreshCoordinatorTheBalanceResponseCouldNotBeParsed), client: client)
                    }
                }
            }
            }
        ) else {
            return
        }
    }

    /// Interval between automatic official reads. The user's setting is a desired
    /// interval; each source never goes below its own floor.
    private func officialInterval(for client: AssistantClient) -> TimeInterval {
        RefreshPolicy.officialInterval(selected: officialRefreshInterval, client: client)
    }

    /// Standard-provider entry for Claude official: asks the scheduler for a read
    /// when one is due and publishes whatever the merge engine already knows.
    private func refreshClaudeStandard(current: CCSwitchProvider, sourceKey: String, sourceChanged: Bool, userInitiated: Bool) {
        guard let claudeQuota else { return }
        lastStandardSourceKey = sourceKey
        claudeStandardTarget = (current.id, current.name, current.configurationRevision)
        if sourceChanged { lastClaudePublication = nil }
        claudeQuota.start()
        claudeQuota.setDemand(true)
        claudeQuota.tick()
        if userInitiated {
            claudeQuota.requestFetch(reason: .manual)
        } else if sourceChanged {
            claudeQuota.requestFetch(reason: .initial)
        }
        if sourceChanged, let state = claudeQuota.latestState { applyClaudeState(state) }
    }

    /// Claude official Providers that currently show the account's quota. The standard
    /// target counts only while it is still the current, unchanged Provider.
    private var claudeOfficialProviderIDs: Set<String> {
        var ids = Set(knownOfficialSummaryIDs.filter { $0.client == .claude }.map(\.providerID))
        if let target = claudeStandardTarget,
           standardRequestIsCurrent(client: .claude, providerID: target.providerID, revision: target.revision) {
            ids.insert(target.providerID)
        }
        return ids
    }

    /// Publishes pipeline state to the standard card, the quick-switch summaries and notifications.
    private func applyClaudeState(_ state: ClaudeQuotaState) {
        actions.notificationAccountScopeChanged?(.claude, state.accountScope)
        let accountChanged = claudeObservedEpoch.map { $0 != state.accountEpoch } ?? false
        claudeObservedEpoch = state.accountEpoch
        if accountChanged {
            SwitchLog.write("claude official account changed; visible quota cleared; scope_omitted=true",
                level: .info, category: "refresh.summary")
            invalidateClaudeAccountData()
        }
        if state.failure != nil { actions.notificationSamplesInvalidated?(.claude, claudeOfficialProviderIDs) }
        applyClaudeSummaries(state)
        guard let target = claudeStandardTarget else { return }
        let snapshot: Snapshot
        if !state.windows.isEmpty {
            let representative = state.windows.first(where: { $0.kind == .sevenDay })
                ?? state.windows.first(where: { $0.kind == .fiveHour }) ?? state.windows[0]
            // Claude windows share the Codex prediction-cycle journal: identical
            // qualification, refill/reset invalidation and account scoping. The
            // journal is account-wide (not per Provider), like the read itself;
            // its key is the pipeline's stable account ID (account + organization
            // UUID), so same-email Claude accounts never share a journal, and the
            // ID's "claude:" namespace cannot collide with a Codex email journal.
            let predictionContexts = state.predictionEvidenceKey.map {
                codexResetObservationStore.updatePredictionContexts(
                    providerID: "claude-official", accountKey: $0,
                    windows: state.windows, now: now())
            } ?? []
            var official = Snapshot.official(target.providerName, representative.remaining, representative.label,
                representative.reset, state.updatedAt ?? now(), windows: state.windows,
                quotaPredictionContexts: predictionContexts,
                quotaPredictionAccountKey: state.predictionAccountKey)
            official.notificationAccountScope = state.accountScope
            official.quotaStatus = state.status
            // Keep the account's last data visible; the reason rides on the refresh time.
            official.staleReason = state.failure.map(Self.claudeFailureReason)
            snapshot = official
        } else if let failure = state.failure {
            var error = Snapshot.providerError(target.providerName, reason: Self.claudeFailureReason(failure), cachedBalance: nil)
            error.quotaStatus = state.status
            snapshot = error
        } else {
            return
        }
        if let last = lastClaudePublication, last.providerID == target.providerID,
           last.revision == target.revision, last.snapshot == snapshot { return }
        lastClaudePublication = (target.providerID, target.revision, snapshot)
        renderForCurrentProvider(snapshot, providerID: target.providerID, client: .claude,
            configurationRevision: target.revision, notifies: false)
    }

    /// Every Claude official Provider shows the same account-wide windows.
    private func applyClaudeSummaries(_ state: ClaudeQuotaState) {
        guard !state.windows.isEmpty else { return }
        for id in claudeOfficialProviderIDs {
            updateQuickSwitchSummary(providerID: id, client: .claude, payload: .officialWindows(state.windows))
        }
    }

    /// Official snapshots that passed the adapter reach the existing notification rules
    /// for every Claude official Provider, matching the per-Provider samples used before.
    private func forwardClaudeNotification(_ snapshot: Snapshot) {
        for id in claudeOfficialProviderIDs { actions.notificationSnapshot?(.claude, id, snapshot) }
    }

    /// Drops everything derived from the previous Claude account: summary
    /// payloads, both official cadences, and the standard display. The next
    /// refresh requests the new account immediately.
    private func invalidateClaudeAccountData() {
        lastOfficialSummaryFetch = lastOfficialSummaryFetch.filter { $0.key.client != .claude }
        quickSwitchSummaryLock.lock()
        let summaryIDs = quickSwitchSummaryPayloads.compactMap { identity, payload -> String? in
            guard identity.client == .claude, case .officialWindows = payload else { return nil }
            return identity.providerID
        }
        quickSwitchSummaryLock.unlock()
        summaryIDs.forEach { removeQuickSwitchSummary(providerID: $0, client: .claude) }
        guard let target = claudeStandardTarget else { return }
        lastOfficialFetch = nil
        lastClaudePublication = nil
        clearStandardDisplay(client: .claude, providerID: target.providerID, revision: target.revision)
    }

    private static func claudeFailureReason(_ failure: ClaudeQuotaFailure) -> String {
        let name = String(describing: AssistantClient.claude.displayName)
        switch failure {
        case .missingCredentials:
            return tr(.keyProviderRefreshCoordinatorOfficialValueLocalSignInCredentialsWereNotFound, arguments: [name])
        case let .transport(_, description):
            return tr(.keyProviderRefreshCoordinatorOfficialValueValue, arguments: [name, description])
        case .unauthorized:
            return tr(.keyClaudeRefreshLoginExpired)
        case .rateLimited, .http(429):
            return tr(.keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonHttpTooManyRequestsValue,
                arguments: ["429"]) + "\n" + tr(.keyDashboardGeneralAndRefreshPagesUpdateCheckFailureSuggestionHttpTooManyRequests)
        case .http, .invalidResponse:
            return tr(.keyProviderRefreshCoordinatorOfficialValueTheQuotaEndpointReturnedAnError, arguments: [name])
        }
    }

    /// One shared rule for every official quota and API balance failure
    /// (standard and quick-switch, any status): the stored notification sample is no longer
    /// current and must not be re-evaluated until a real refresh succeeds.
    private func officialSampleUnavailable(client: AssistantClient, providerID: String) {
        actions.notificationSamplesInvalidated?(client, [providerID])
    }

    /// Replaces the visible and per-client cached snapshot with a placeholder.
    private func clearStandardDisplay(client: AssistantClient, providerID: String, revision: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lifetime.isCurrent(),
                  let current = self.actions.currentProvider(client),
                  current.isOfficial, current.id == providerID,
                  current.configurationRevision == revision else { return }
            if let storeWithRevision = self.actions.storeClientSnapshotWithRevision {
                storeWithRevision(client, providerID, revision, .placeholder)
            } else {
                self.actions.storeClientSnapshot(client, providerID, .placeholder)
            }
            guard self.actions.isActiveClient(client) else { return }
            if let ownedRender = self.actions.ownedRender { ownedRender(providerID, .placeholder) }
            else { self.actions.render(.placeholder) }
        }
    }

    /// Requests made before this check must belong to the account still signed in.
    /// Claude's account identity is tracked by `ClaudeQuotaPipeline` instead.
    private func officialCredentialsAreCurrent(client: AssistantClient, storedAccessToken: String?,
                                               credentials: CodexRequestCredentials?) -> Bool {
        switch client {
        case .codex: return storedAccessToken != nil || officialQuotaClient.codexRequestCredentials() == credentials
        case .claude, .grok: return true
        }
    }

    @discardableResult
    private func fetchOfficialQuota(providerID: String, providerName: String, client: AssistantClient,
                                    source: ProviderSummarySource? = nil,
                                    requestContext: OfficialQuotaRequestContext? = nil,
                                    configurationRevision: String = "",
                                    isValid: @escaping () -> Bool = { true },
                                    completion: ((Snapshot) -> Void)? = nil) -> OfficialQuotaRequestContext? {
        func publish(_ snapshot: Snapshot, providerID: String, client: AssistantClient,
                     isCurrentRequest: @escaping () -> Bool = { true }) {
            guard isValid(), isCurrentRequest() else { return }
            if let completion { completion(snapshot) }
            else {
                renderForCurrentProvider(
                    snapshot,
                    providerID: providerID,
                    client: client,
                    configurationRevision: configurationRevision,
                    isCurrentRequest: isCurrentRequest
                )
            }
        }
        func fail(providerID: String, providerName: String, reason: String, client: AssistantClient,
                  isCurrentRequest: @escaping () -> Bool) {
            if isValid(), isCurrentRequest() { officialSampleUnavailable(client: client, providerID: providerID) }
            publish(.providerError(providerName, reason: reason, cachedBalance: nil), providerID: providerID, client: client, isCurrentRequest: isCurrentRequest)
        }
        // Demo bundles bypass real transport for both the direct provider and
        // aggregated provider rows, so the fixture stays visible regardless of
        // the user's aggregation setting.
        if client == .codex, let demoSnapshot = DevelopmentLunaReserveDemo.snapshot(providerName: providerName)
            ?? DevelopmentBankedResetDemo.snapshot(providerName: providerName) {
            publish(
                demoSnapshot,
                providerID: providerID,
                client: client
            )
            return nil
        }
        // Freeze the account before transport starts. Never assign a late
        // response to the auth profile that happens to be current on arrival.
        let credentials: CodexRequestCredentials?
        switch client {
        case _ where requestContext != nil: credentials = requestContext?.credentials
        case .codex: credentials = source?.officialAccessToken.map {
            CodexRequestCredentials(accessToken: $0, accountKey: source?.officialAccount?.email?.lowercased())
        } ?? officialQuotaClient.codexRequestCredentials()
        case .claude, .grok: credentials = nil
        }
        let context = requestContext ?? OfficialQuotaRequestContext(client: client, providerID: providerID,
            storedAccessToken: source?.officialAccessToken, credentials: credentials)
        let credentialsMatch = { [weak self] (_: Bool) -> Bool in
            guard let self, isValid() else { return false }
            return self.officialCredentialsAreCurrent(client: client, storedAccessToken: source?.officialAccessToken,
                credentials: credentials)
        }
        let accountKey = credentials?.accountKey
        if source == nil {
            if let previous = standardOfficialRequests[client],
               previous.providerID != context.providerID || previous.credentials != context.credentials {
                officialQuotaClient.cancelQuota(context: previous)
            }
            standardOfficialRequests[client] = context
        }
        officialQuotaClient.fetchQuota(context: context) { [weak self] result in
            guard let self else { return }
            self.performOnQueue {
                guard credentialsMatch(true) else { return }
                // Every completed quota response owns a new generation, including
                // errors. Pending credit/forecast callbacks from older successes
                // must not replace a newer failure or mutate its observation state.
                let responseKey = client.rawValue + "|" + providerID + "|" + (credentials?.requestScope ?? "")
                self.officialResponseGenerations[responseKey]?.invalidate()
                let generation = OfficialResponseGeneration()
                self.officialResponseGenerations[responseKey] = generation
                let isCurrentQuota = { generation.isCurrent() }
                switch result {
                case .success(let response):
                    let quotaNow = self.now()
                    let predictionContexts: [QuotaPredictionContext]
                    if client == .codex, let accountKey {
                        predictionContexts = self.recordCodexQuotaEvidence(providerID: providerID, accountKey: accountKey,
                            windows: response.output.windows, timestamp: quotaNow)
                    } else { predictionContexts = [] }
                    self.updateQuickSwitchSummary(
                        providerID: providerID,
                        client: client,
                        payload: .officialWindows(response.output.windows)
                    )
                    let renderOfficial: (CodexBankedReset?, CodexResetForecast) -> Void = { bankedReset, forecast in
                        guard credentialsMatch(false),
                              isCurrentQuota() else { return }
                        let resolvedForecast = client == .codex ? self.resolveCodexResetObservation(
                            providerID: providerID,
                            windows: response.output.windows,
                            forecast: forecast,
                            accountKey: accountKey,
                            client: client
                        ) : .unavailable
                        var snapshot = Snapshot.official(
                            providerName,
                            response.output.remaining,
                            response.output.label,
                            response.output.reset,
                            response.fetchedAt,
                            windows: response.output.windows,
                            lunaReserve: response.output.lunaReserve,
                            bankedReset: client == .codex ? bankedReset : nil,
                            resetForecast: resolvedForecast,
                            quotaPredictionContexts: predictionContexts,
                            quotaPredictionAccountKey: client == .codex ? accountKey : nil
                        )
                        publish(
                            snapshot,
                            providerID: providerID,
                            client: client,
                            isCurrentRequest: { isCurrentQuota() && credentialsMatch(false) }
                        )
                    }
                    // Observation consumes successful quota data immediately,
                    // independently of credit-list transport. Keep the existing
                    // forecast eligibility; no-card quota refreshes use a cached
                    // signal without initiating extra forecast polling.
                    let cachedForecast: CodexResetForecast = client == .codex
                        ? (self.cachedCodexResetForecast?.forecast.markingCached() ?? .unavailable) : .unavailable
                    _ = self.resolveCodexResetObservation(
                        providerID: providerID, windows: response.output.windows,
                        forecast: cachedForecast, accountKey: accountKey, client: client
                    )
                    let finishOfficial: (CodexBankedReset?) -> Void = { bankedReset in
                        self.performOnQueue {
                            guard credentialsMatch(false),
                                  isCurrentQuota() else { return }
                            guard client == .codex, bankedReset != nil || self.cachedCodexResetForecast != nil else {
                                renderOfficial(bankedReset, cachedForecast)
                                return
                            }
                            self.provideCodexResetForecast(includingCached: source == nil) { forecast in
                                renderOfficial(bankedReset, forecast)
                            }
                        }
                    }
                    if client == .codex && response.output.bankedResetNeedsCreditList {
                        self.officialQuotaClient.fetchRateLimitResetCredits(storedAccessToken: credentials?.accessToken, context: context, now: self.now()) { creditsResult in
                            switch creditsResult {
                            case .success(let bankedReset):
                                finishOfficial(bankedReset)
                            case .failure:
                                finishOfficial(nil)
                            }
                        }
                    } else {
                        finishOfficial(response.output.bankedReset)
                    }
                case .failure(.missingCredentials):
                    fail(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr(.keyProviderRefreshCoordinatorOfficialValueLocalSignInCredentialsWereNotFound, arguments: [String(describing: client.displayName)]),
                        client: client,
                        isCurrentRequest: { isCurrentQuota() && credentialsMatch(false) }
                    )
                case .failure(.transport(let error)):
                    fail(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr(.keyProviderRefreshCoordinatorOfficialValueValue, arguments: [String(describing: client.displayName), String(describing: error.localizedDescription)]),
                        client: client,
                        isCurrentRequest: { isCurrentQuota() && credentialsMatch(false) }
                    )
                case .failure(.httpStatus(let status, _)) where status == 429:
                    let reason = tr(.keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonHttpTooManyRequestsValue,
                        arguments: [String(status)]) + "\n" + tr(.keyDashboardGeneralAndRefreshPagesUpdateCheckFailureSuggestionHttpTooManyRequests)
                    fail(providerID: providerID, providerName: providerName, reason: reason, client: client,
                        isCurrentRequest: { isCurrentQuota() && credentialsMatch(false) })
                case .failure:
                    fail(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr(.keyProviderRefreshCoordinatorOfficialValueTheQuotaEndpointReturnedAnError, arguments: [String(describing: client.displayName)]),
                        client: client,
                        isCurrentRequest: { isCurrentQuota() && credentialsMatch(false) }
                    )
                }
            }
        }
        return context
    }

    /// Recomputes countdowns from each window's absolute reset time so a kept
    /// snapshot does not show the countdown from when it was fetched.
    static func staleOfficialSnapshot(_ snapshot: Snapshot, reason: String, now: Date) -> Snapshot {
        let windows = snapshot.officialQuotaWindows.map { window -> OfficialQuotaWindow in
            guard let resetAt = window.resetAt else { return window }
            return OfficialQuotaWindow(kind: window.kind, remaining: window.remaining, label: window.label,
                daysText: window.daysText,
                reset: ResponseParsingSupport.resetDescription(resetAt.timeIntervalSince1970, now: now),
                durationSeconds: window.durationSeconds, resetAt: resetAt)
        }
        let representative = windows.first(where: { $0.kind == .sevenDay }) ?? windows.first(where: { $0.kind == .fiveHour }) ?? windows.first
        var stale = Snapshot.official(snapshot.provider, snapshot.amount ?? representative?.remaining ?? 0,
            snapshot.unit ?? representative?.label ?? "", representative?.reset, snapshot.date ?? now,
            windows: windows, lunaReserve: snapshot.lunaReserve, bankedReset: snapshot.bankedReset,
            resetForecast: snapshot.resetForecast, quotaPredictionContexts: snapshot.quotaPredictionContexts,
            quotaPredictionAccountKey: snapshot.quotaPredictionAccountKey)
        stale.staleReason = reason
        stale.notificationAccountScope = snapshot.notificationAccountScope
        return stale
    }

    /// Official quota evidence is captured before any forecast/credit transport.
    /// The journal is account-local and never by itself publishes a reset status.
    private func recordCodexQuotaEvidence(providerID: String, accountKey: String,
                                          windows: [OfficialQuotaWindow], timestamp: Date) -> [QuotaPredictionContext] {
        guard timestamp.timeIntervalSince1970.isFinite else { return [] }
        if let sample = CodexResetQuotaSample.make(from: windows) {
            let key = observationCacheKey(providerID: providerID, accountKey: accountKey)
            var evidence = codexQuotaEvidence[key]
                ?? codexResetObservationStore.loadQuotaEvidence(providerID: providerID, accountKey: accountKey)
                ?? CodexResetObservation()
            if let previous = evidence.previousSample, previous.sevenDayResetAt <= timestamp {
                // Preserve the actual rollover comparison. Drop an expired baseline
                // only when this sample cannot establish a complete cycle transition.
                let completesTransition = evidence.observedConsumption && sample.isComplete
                    && sample.sevenDayResetAt.timeIntervalSince(previous.sevenDayResetAt) >= CodexResetObservation.minimumResetCycleJump
                    && sample.sevenDayResetAt > timestamp
                if !completesTransition { evidence = CodexResetObservation() }
            }
            evidence.observeLatestQuotaEvent(sample, now: timestamp)
            codexQuotaEvidence[key] = evidence
            codexResetObservationStore.saveQuotaEvidence(providerID: providerID, accountKey: accountKey, evidence: evidence)
        }
        return codexResetObservationStore.updatePredictionContexts(
            providerID: providerID, accountKey: accountKey, windows: windows, now: timestamp)
    }

    private func resetCodexQuotaEvidenceBaseline(providerID: String, accountKey: String, windows: [OfficialQuotaWindow], clearOnMissingSample: Bool = false) {
        let sample = CodexResetQuotaSample.make(from: windows)
        guard sample != nil || clearOnMissingSample else { return }
        var baseline = CodexResetObservation()
        if let sample {
            baseline.observe(sample, now: now())
        }
        codexQuotaEvidence[observationCacheKey(providerID: providerID, accountKey: accountKey)] = baseline
        codexResetObservationStore.saveQuotaEvidence(providerID: providerID, accountKey: accountKey, evidence: baseline)
    }

    private func resolveCodexResetObservation(
        providerID: String,
        windows: [OfficialQuotaWindow],
        forecast: CodexResetForecast,
        accountKey: String?,
        client: AssistantClient
    ) -> CodexResetForecast {
        guard client == .codex else { return forecast }
        guard forecast.hasAnyValue else { return forecast }
        guard let accountKey else {
            return forecast.applyingOfficialResetObservation(.notEligible)
        }
        guard let signal = forecast.officialSignal else {
            codexResetObservations.removeValue(forKey: observationCacheKey(providerID: providerID, accountKey: accountKey))
            codexResetObservationStore.remove(providerID: providerID, accountKey: accountKey)
            if !forecast.isCached {
                resetCodexQuotaEvidenceBaseline(providerID: providerID, accountKey: accountKey, windows: windows, clearOnMissingSample: true)
            }
            return forecast.applyingOfficialResetObservation(.notEligible)
        }

        let episodeKey = signal.episodeKey ?? "active"
        let cacheKey = observationCacheKey(providerID: providerID, accountKey: accountKey)
        // Anonymous episodes can be tracked during this process only. Never
        // resurrect an "active" state after an unobserved signal boundary.
        let durable = signal.episodeKey != nil
        let priorEntry = codexResetObservations[cacheKey]
            ?? (durable ? codexResetObservationStore.load(providerID: providerID, accountKey: accountKey) : nil)
        var seed = CodexResetObservation()
        if durable, priorEntry?.episodeKey != episodeKey,
           let publishedAt = signal.publishedAt,
           let pending = codexQuotaEvidence[cacheKey],
           let baselineAt = pending.state == .observed ? pending.resetTransitionStartedAt : pending.previousSampleAt,
           baselineAt >= publishedAt, baselineAt <= now() {
            // Both ends of an unassigned transition must belong to this signal's
            // time window. Undated legacy evidence never confirms a new episode,
            // and an event already assigned to another episode cannot be reused.
            if pending.state != .observed, pending.previousSample?.hasConsumption == true {
                seed = pending
            } else if let detectedAt = pending.detectedAt,
                      detectedAt >= baselineAt, detectedAt <= now(),
                      priorEntry?.observation.confirmedDetectedAt != detectedAt {
                seed = pending
            }
        }
        var entry = priorEntry ?? (episodeKey: episodeKey, observation: seed)
        if entry.episodeKey != episodeKey {
            entry = (episodeKey: episodeKey, observation: seed)
        }
        if let sample = CodexResetQuotaSample.make(from: windows) {
            var observation = entry.observation
            observation.observe(sample, now: now())
            if !forecast.isCached { observation.confirmDetectedEvent() }
            entry = (episodeKey: episodeKey, observation: observation)
            codexResetObservations[cacheKey] = entry
            if durable {
                codexResetObservationStore.save(
                    providerID: providerID,
                    accountKey: accountKey,
                    episodeKey: episodeKey,
                    observation: observation
                )
            } else {
                codexResetObservationStore.remove(providerID: providerID, accountKey: accountKey)
            }
        } else {
            codexResetObservations[cacheKey] = entry
        }
        if !forecast.isCached {
            resetCodexQuotaEvidenceBaseline(providerID: providerID, accountKey: accountKey, windows: windows)
        }
        return forecast.applyingOfficialResetObservation(entry.observation.state)
    }

    private func observationCacheKey(providerID: String, accountKey: String) -> String {
        providerID + "|" + accountKey
    }

    private func provideCodexResetForecast(
        includingCached: Bool = true,
        completion: @escaping (CodexResetForecast) -> Void
    ) {
        performOnQueue { [weak self] in
            guard let self else { return }
            let now = self.now()
            if let cached = self.cachedCodexResetForecast,
               now.timeIntervalSince(cached.fetchedAt) < Self.codexResetForecastTTL {
                completion(cached.forecast.markingCached())
                return
            }

            let fallback = self.cachedCodexResetForecast?.forecast.markingCached() ?? .unavailable
            if !self.forecastRequestInFlight,
               let attempted = self.lastForecastAttempt,
               now.timeIntervalSince(attempted) < Self.codexResetForecastRetryInterval {
                completion(fallback)
                return
            }
            if includingCached { completion(fallback) }
            self.inFlightForecastCompletions.append(completion)
            guard !self.forecastRequestInFlight else { return }
            self.forecastRequestInFlight = true
            self.lastForecastAttempt = now
            self.officialQuotaClient.fetchCodexResetForecast { [weak self] forecast in
                guard let self else { return }
                self.performOnQueue {
                    if forecast.hasAnyValue {
                        self.cachedCodexResetForecast = CachedCodexResetForecast(
                            forecast: forecast.markingFresh(),
                            fetchedAt: self.now()
                        )
                    }
                    let resolved: CodexResetForecast
                    if forecast.hasAnyValue {
                        resolved = forecast.markingFresh()
                    } else if let cached = self.cachedCodexResetForecast {
                        resolved = cached.forecast.markingCached()
                    } else {
                        resolved = .unavailable
                    }
                    let completions = self.inFlightForecastCompletions
                    self.inFlightForecastCompletions = []
                    self.forecastRequestInFlight = false
                    for pending in completions {
                        pending(resolved)
                    }
                }
            }
        }
    }

    private func renderForCurrentProvider(
        _ next: Snapshot,
        providerID: String,
        client: AssistantClient,
        configurationRevision: String = "",
        notifies: Bool = true,
        isCurrentRequest: @escaping () -> Bool = { true }
    ) {
        queue.async { [weak self] in
            guard let self, self.lifetime.isCurrent(), isCurrentRequest(),
                  self.standardRequestIsCurrent(client: client, providerID: providerID, revision: configurationRevision),
                  client != .codex || self.aggregationEntries.isEmpty else { return }
            let epoch = self.standardPublicationEpoch
            if next.kind == .balance {
                self.providerBalanceSnapshots.store(
                    next,
                    clientID: client.rawValue,
                    providerID: providerID,
                    configurationRevision: configurationRevision
                )
            }
            // A kept (stale) snapshot still reaches notifications so they can mark
            // the stored sample as not current; it is never evaluated as a sample.
            if notifies, next.kind == .official || next.kind == .balance {
                self.actions.notificationSnapshot?(client, providerID, next)
            }
            DispatchQueue.main.async {
                guard self.lifetime.isCurrent(), isCurrentRequest(), client != .codex || epoch.isCurrent() else { return }
                guard let current = self.actions.currentProvider(client),
                      current.id == providerID,
                      current.configurationRevision == configurationRevision else { return }
                if next.kind == .official || next.kind == .balance {
                    if let storeWithRevision = self.actions.storeClientSnapshotWithRevision {
                        storeWithRevision(client, providerID, configurationRevision, next)
                    } else {
                        self.actions.storeClientSnapshot(client, providerID, next)
                    }
                }
                guard self.actions.isActiveClient(client) else { return }
                if let ownedRender = self.actions.ownedRender { ownedRender(providerID, next) }
                else { self.actions.render(next) }
            }
        }
    }

    private func renderBalanceError(
        providerID: String,
        providerName: String,
        reason: String,
        client: AssistantClient,
        configurationRevision: String = ""
    ) {
        queue.async { [weak self] in
            guard let self, self.lifetime.isCurrent(),
                  self.standardRequestIsCurrent(client: client, providerID: providerID, revision: configurationRevision),
                  client != .codex || self.aggregationEntries.isEmpty else { return }
            let epoch = self.standardPublicationEpoch
            let next = self.providerBalanceSnapshots.errorSnapshot(
                clientID: client.rawValue,
                providerID: providerID,
                providerName: providerName,
                reason: reason,
                configurationRevision: configurationRevision
            )
            DispatchQueue.main.async {
                guard self.lifetime.isCurrent(), (client != .codex || epoch.isCurrent()),
                      self.actions.isActiveClient(client),
                      let current = self.actions.currentProvider(client),
                      current.id == providerID,
                      current.configurationRevision == configurationRevision else { return }
                if let ownedRender = self.actions.ownedRender { ownedRender(providerID, next) }
                else { self.actions.render(next) }
            }
        }
    }

    private static func formatBalanceSummary(_ amount: Double, unit: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        switch unit.uppercased() {
        case "USD": return "$\(number)"
        case "CNY", "CNH", "RMB": return "¥\(number)"
        default: return "\(number) \(unit)"
        }
    }

    private static func formatOfficialQuotaSummary(_ window: OfficialQuotaWindow) -> String {
        "\(Int(window.remaining))% / \(window.daysText)"
    }

    private static func localizedNetworkErrorReason(_ error: Error) -> String {
        localizedBalanceNetworkErrorReason(error, language: AppLanguage.resolved)
    }

    static func localizedBalanceNetworkErrorReason(_ error: Error, language: AppLanguage) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return tr(.keyProviderRefreshCoordinatorNetworkRequestFailed, language: language)
        }
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            return tr(.keyProviderRefreshCoordinatorNetworkRequestTimedOut, language: language)
        case .notConnectedToInternet:
            return tr(.keyProviderRefreshCoordinatorNoInternetConnection, language: language)
        case .networkConnectionLost:
            return tr(.keyProviderRefreshCoordinatorNetworkConnectionWasLost, language: language)
        case .cannotFindHost:
            return tr(.keyProviderRefreshCoordinatorHostCouldNotBeFound, language: language)
        case .cannotConnectToHost:
            return tr(.keyProviderRefreshCoordinatorCouldNotConnectToHost, language: language)
        case .secureConnectionFailed:
            return tr(.keyProviderRefreshCoordinatorSecureConnectionFailed, language: language)
        default:
            return tr(.keyProviderRefreshCoordinatorNetworkRequestFailed2, language: language)
        }
    }
}
