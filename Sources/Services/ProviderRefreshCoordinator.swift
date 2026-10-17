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
        case .confirmed:
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
        }
        return .official(
            providerName,
            windows[1].remaining,
            windows[1].label,
            windows[1].reset,
            date,
            windows: windows,
            bankedReset: CodexBankedReset(cards: cardList),
            resetForecast: forecast
        )
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
    private let actions: ProviderRefreshActions
    private let codexResetObservationStore: CodexResetObservationStore
    // Cadence timestamps are owned by `queue`; public entry points never read
    // or write them until their work reaches that serial boundary.
    private var lastBalanceFetch: Date?
    private var lastOfficialFetch: Date?
    private var lastQuickSwitchFetch: [AssistantClient: Date] = [:]
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
    static let codexResetForecastTTL: TimeInterval = 10 * 60
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
        now: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.officialQuotaClient = officialQuotaClient
        self.balanceAPIClient = balanceAPIClient
        self.balanceProgressStore = balanceProgressStore
        self.codexResetObservationStore = codexResetObservationStore
        self.queue = queue
        self.now = now
        self.actions = actions
        queue.setSpecific(key: queueKey, value: ())
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
    func refreshAggregation(reader: CCSwitchAggregationRepository, force: Bool) -> Bool {
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
            let interval = TimeInterval(max(60, (entry.source.query?.intervalMinutes ?? 1) * 60))
            let due = aggregationAttempts[identity].map { now().timeIntervalSince($0) >= interval } ?? true
            if (force || due), aggregationRequests[identity] == nil, !aggregationPending.contains(identity) {
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
            self.lastQuickSwitchFetch = [:]
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
        switched: Bool
    ) {
        performOnQueue { [weak self] in
            self?.refreshStandardProviderOnQueue(
                current: current,
                client: client,
                forceBalance: forceBalance,
                switched: switched
            )
        }
    }

    private func refreshStandardProviderOnQueue(
        current: CCSwitchProvider,
        client: AssistantClient,
        forceBalance: Bool,
        switched: Bool
    ) {
        let sourceKey = "\(client.appType)|\(current.id)|\(current.configurationRevision)"
        let sourceChanged = lastStandardSourceKey != sourceKey
        guard let query = current.query else {
            guard current.isOfficial, client == .codex else {
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
            let currentDate = now()
            let due = lastOfficialFetch.map { currentDate.timeIntervalSince($0) >= 60 } ?? true
            guard forceBalance || switched || sourceChanged || due else { return }
            if standardIdentityChanged(from: lastStandardSourceKey, client: client, provider: current) != nil,
               let previous = standardOfficialRequests[client] {
                officialQuotaClient.cancelQuota(context: previous)
            }
            lastStandardSourceKey = sourceKey
            lastOfficialFetch = currentDate
            let revision = current.configurationRevision
            fetchOfficialQuota(
                providerID: current.id,
                providerName: current.name,
                client: client,
                configurationRevision: revision,
                isValid: { [weak self] in self?.standardRequestIsCurrent(client: client, providerID: current.id, revision: revision) == true }
            )
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
            let due = self.lastQuickSwitchFetch[client].map { currentDate.timeIntervalSince($0) >= 60 } ?? true
            SwitchLog.write("quick-switch refresh triggered; force=\(force); ttl_due=\(due); configuration_event=\(configurationChanged)", level: .debug,
                category: "refresh.summary", throttleKey: "summary-trigger-\(force)", minimumInterval: 1)
            guard force || due || configurationChanged else { return }
            guard let sources = try? self.repository.loadSummarySourcesChecked(appType: client.appType) else { return }
            let previousRevisions = self.quickSwitchSourceRevisions[client] ?? [:]
            self.quickSwitchSourceRevisions[client] = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.configurationRevision) })
            self.invalidateStaleQuickSwitchSummaries(client: client, sources: sources, previousRevisions: previousRevisions)
            if force || due { self.lastQuickSwitchFetch[client] = currentDate }
            let aggregationIDs: Set<String>
            if client == .codex, let reader = self.aggregationReader, case .active(let entries) = reader.load() {
                _ = self.refreshAggregation(reader: reader, force: force)
                aggregationIDs = Set(entries.map(\.providerID))
            } else { aggregationIDs = [] }
            self.balanceProgressStore.prepareMigration(identities: sources.compactMap { source in
                source.query.map { ProviderBalanceProgressIdentity(client: client, providerID: source.id, query: $0, providerName: source.name) }
            })
            for source in sources {
                guard force || due || previousRevisions[source.id] != source.configurationRevision else { continue }
                if aggregationIDs.contains(source.id) { continue }
                if let providerIDs, !providerIDs.contains(source.id) { continue }
                if source.isOfficial {
                    if client != .codex { continue }
                    let credentials = source.officialAccessToken.map {
                        CodexRequestCredentials(accessToken: $0, accountKey: nil)
                    } ?? self.officialQuotaClient.codexRequestCredentials()
                    self.officialQuotaClient.fetchQuota(
                        client: client,
                        providerID: source.id,
                        storedAccessToken: source.officialAccessToken,
                        requestCredentials: credentials
                    ) { [weak self] result in
                        guard let self else { return }
                        self.performOnQueue {
                            guard self.quickSwitchSourceIsCurrent(
                                client: client, providerID: source.id, revision: source.configurationRevision
                            ) else { return }
                            guard let currentSource = self.repository.loadSummarySources(appType: client.appType).first(where: { $0.id == source.id && $0.isOfficial }),
                                  currentSource.officialAccessToken == source.officialAccessToken,
                                  source.officialAccessToken != nil || self.officialQuotaClient.codexRequestCredentials() == credentials else { return }
                            guard case .success(let response) = result else {
                                if previousRevisions[source.id] != source.configurationRevision {
                                    self.removeQuickSwitchSummary(providerID: source.id, client: client)
                                }
                                return
                            }
                            let quotaNow = self.now()
                            let predictionContexts = credentials.accountKey.map {
                                self.recordCodexQuotaEvidence(providerID: source.id, accountKey: $0,
                                    windows: response.output.windows, timestamp: quotaNow)
                            } ?? []
                            self.updateQuickSwitchSummary(
                                providerID: source.id,
                                client: client,
                                payload: .officialWindows(response.output.windows)
                            )
                            self.actions.notificationSnapshot?(
                                client,
                                source.id,
                                .official(
                                    source.name,
                                    response.output.remaining,
                                    response.output.label,
                                    response.output.reset,
                                    quotaNow,
                                    windows: response.output.windows,
                                    lunaReserve: response.output.lunaReserve,
                                    quotaPredictionContexts: predictionContexts,
                                    quotaPredictionAccountKey: credentials.accountKey
                                )
                            )
                        }
                    }
                    continue
                }
                guard let query = source.query else { continue }
                let sampleSequence = self.balanceProgressStore.beginSample()
                self.balanceAPIClient.fetchBalance(
                    query: query,
                    client: client,
                    providerID: source.id
                ) { [weak self] result in
                    guard let self else { return }
                    self.performOnQueue {
                        guard self.quickSwitchSourceIsCurrent(
                            client: client, providerID: source.id, revision: source.configurationRevision
                        ) else { return }
                        guard case .success(let response) = result else {
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

    private func quickSwitchSourceIsCurrent(client: AssistantClient, providerID: String, revision: String) -> Bool {
        guard quickSwitchSourceRevisions[client]?[providerID] == revision,
              let source = try? repository.loadSummarySourcesChecked(appType: client.appType)
                .first(where: { $0.id == providerID }) else { return false }
        return source.configurationRevision == revision
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

    private func fetchOfficialQuota(providerID: String, providerName: String, client: AssistantClient,
                                    source: ProviderSummarySource? = nil,
                                    requestContext: OfficialQuotaRequestContext? = nil,
                                    configurationRevision: String = "",
                                    isValid: @escaping () -> Bool = { true },
                                    completion: ((Snapshot) -> Void)? = nil) {
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
            publish(.providerError(providerName, reason: reason, cachedBalance: nil), providerID: providerID, client: client, isCurrentRequest: isCurrentRequest)
        }
        if source == nil, let demoSnapshot = DevelopmentLunaReserveDemo.snapshot(providerName: providerName)
            ?? DevelopmentBankedResetDemo.snapshot(providerName: providerName) {
            publish(
                demoSnapshot,
                providerID: providerID,
                client: client
            )
            return
        }
        // Freeze the account before transport starts. Never assign a late
        // response to the auth profile that happens to be current on arrival.
        let credentials = requestContext?.credentials ?? (client == .codex ? source?.officialAccessToken.map {
            CodexRequestCredentials(accessToken: $0, accountKey: source?.officialAccount?.email?.lowercased())
        } ?? officialQuotaClient.codexRequestCredentials() : nil)
        let context = requestContext ?? OfficialQuotaRequestContext(client: client, providerID: providerID,
            storedAccessToken: source?.officialAccessToken, credentials: credentials)
        let credentialsMatch = { [weak self] in
            guard let self, isValid() else { return false }
            return client != .codex || source?.officialAccessToken != nil || self.officialQuotaClient.codexRequestCredentials() == credentials
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
                guard credentialsMatch() else { return }
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
                        guard credentialsMatch(),
                              isCurrentQuota() else { return }
                        let resolvedForecast = self.resolveCodexResetObservation(
                            providerID: providerID,
                            windows: response.output.windows,
                            forecast: forecast,
                            accountKey: accountKey,
                            client: client
                        )
                        publish(
                            .official(
                                providerName,
                                response.output.remaining,
                                response.output.label,
                                response.output.reset,
                                quotaNow,
                                windows: response.output.windows,
                                lunaReserve: response.output.lunaReserve,
                                bankedReset: bankedReset,
                                resetForecast: resolvedForecast,
                                quotaPredictionContexts: predictionContexts,
                                quotaPredictionAccountKey: client == .codex ? accountKey : nil
                            ),
                            providerID: providerID,
                            client: client,
                            isCurrentRequest: { isCurrentQuota() && (credentialsMatch()) }
                        )
                    }
                    // Observation consumes successful quota data immediately,
                    // independently of credit-list transport. Keep the existing
                    // forecast eligibility; no-card quota refreshes use a cached
                    // signal without initiating extra forecast polling.
                    let cachedForecast = self.cachedCodexResetForecast?.forecast.markingCached() ?? .unavailable
                    _ = self.resolveCodexResetObservation(
                        providerID: providerID, windows: response.output.windows,
                        forecast: cachedForecast, accountKey: accountKey, client: client
                    )
                    let finishOfficial: (CodexBankedReset?) -> Void = { bankedReset in
                        self.performOnQueue {
                            guard credentialsMatch(),
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
                        isCurrentRequest: { isCurrentQuota() && (credentialsMatch()) }
                    )
                case .failure(.transport(let error)):
                    fail(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr(.keyProviderRefreshCoordinatorOfficialValueValue, arguments: [String(describing: client.displayName), String(describing: error.localizedDescription)]),
                        client: client,
                        isCurrentRequest: { isCurrentQuota() && (credentialsMatch()) }
                    )
                case .failure:
                    fail(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr(.keyProviderRefreshCoordinatorOfficialValueTheQuotaEndpointReturnedAnError, arguments: [String(describing: client.displayName)]),
                        client: client,
                        isCurrentRequest: { isCurrentQuota() && (credentialsMatch()) }
                    )
                }
            }
        }
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
            if next.kind == .official || next.kind == .balance {
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
