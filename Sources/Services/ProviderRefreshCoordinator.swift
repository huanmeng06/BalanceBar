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
    let quickSwitchSummaryChanged: (String) -> Void
    var notificationSnapshot: ((AssistantClient, String, Snapshot) -> Void)? = nil
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
    private var quickSwitchSummaryLock = NSLock()
    private var quickSwitchSummaryPayloads: [String: QuickSwitchSummaryPayload] = [:]
    private var providerBalanceSnapshots = ProviderBalanceSnapshotCache()
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
        preferredQuotaWindow: OfficialQuotaWindowPreference
    ) -> [String: String] {
        quickSwitchSummaryLock.lock()
        let payloads = quickSwitchSummaryPayloads
        quickSwitchSummaryLock.unlock()

        var summaries: [String: String] = [:]
        for (providerID, payload) in payloads {
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

    func resetCadence() {
        performOnQueue { [weak self] in
            guard let self else { return }
            self.lastBalanceFetch = nil
            self.lastOfficialFetch = nil
            self.lastQuickSwitchFetch = [:]
        }
    }

    func performAsync(_ work: @escaping () -> Void) {
        queue.async { work() }
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
                    client: client
                )
                return
            }
            let currentDate = now()
            let due = lastOfficialFetch.map { currentDate.timeIntervalSince($0) >= 60 } ?? true
            guard forceBalance || switched || due else { return }
            lastOfficialFetch = currentDate
            fetchOfficialQuota(providerID: current.id, providerName: current.name, client: client)
            return
        }

        let interval = TimeInterval(max(query.intervalMinutes, 1) * 60)
        let currentDate = now()
        let due = lastBalanceFetch.map { currentDate.timeIntervalSince($0) >= interval } ?? true
        guard forceBalance || switched || due else { return }
        lastBalanceFetch = currentDate
        fetchBalance(
            providerID: current.id,
            providerName: current.name,
            query: query,
            client: client
        )
    }

    func prefetchCurrentBalance(for client: AssistantClient) {
        queue.async { [weak self] in
            guard let self, let current = self.repository.loadCurrent(appType: client.appType) else { return }
            if let query = current.query {
                self.fetchBalance(providerID: current.id, providerName: current.name, query: query, client: client)
            } else if current.isOfficial, client == .codex {
                self.fetchOfficialQuota(providerID: current.id, providerName: current.name, client: client)
            }
        }
    }

    func refreshQuickSwitchSummaries(
        force: Bool,
        for requestedClient: AssistantClient? = nil,
        providerIDs: Set<String>? = nil
    ) {
        let client = requestedClient ?? .codex
        queue.async { [weak self] in
            guard let self else { return }
            let currentDate = self.now()
            let due = self.lastQuickSwitchFetch[client].map { currentDate.timeIntervalSince($0) >= 60 } ?? true
            guard force || due else { return }
            self.lastQuickSwitchFetch[client] = currentDate
            for source in self.repository.loadSummarySources(appType: client.appType) {
                if let providerIDs, !providerIDs.contains(source.id) { continue }
                if source.isOfficial {
                    if client != .codex { continue }
                    let credentials = source.officialAccessToken == nil
                        ? self.officialQuotaClient.codexRequestCredentials() : nil
                    self.officialQuotaClient.fetchQuota(
                        client: client,
                        providerID: source.id,
                        storedAccessToken: source.officialAccessToken,
                        requestCredentials: credentials
                    ) { [weak self] result in
                        guard let self, case .success(let response) = result else { return }
                        self.performOnQueue {
                            guard credentials == nil || self.officialQuotaClient.codexRequestCredentials() == credentials else { return }
                            if let accountKey = credentials?.accountKey {
                                self.recordCodexQuotaEvidence(providerID: source.id, accountKey: accountKey, windows: response.output.windows)
                            }
                            self.updateQuickSwitchSummary(
                                providerID: source.id,
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
                                    Date(),
                                    windows: response.output.windows,
                                    lunaReserve: response.output.lunaReserve
                                )
                            )
                        }
                    }
                    continue
                }
                guard let query = source.query else { continue }
                self.balanceAPIClient.fetchBalance(
                    query: query,
                    client: client,
                    providerID: source.id
                ) { [weak self] result in
                    guard let self, case .success(let response) = result else { return }
                    let identity = ProviderBalanceProgressIdentity(
                        client: client,
                        providerID: source.id,
                        query: query
                    )
                    guard case .success = self.balanceProgressStore.update(
                        amount: response.output.amount,
                        unit: response.output.unit,
                        identity: identity
                    ) else { return }
                    self.updateQuickSwitchSummary(
                        providerID: source.id,
                        payload: .formatted(Self.formatBalanceSummary(response.output.amount, unit: response.output.unit))
                    )
                    self.actions.notificationSnapshot?(
                        client,
                        source.id,
                        .balance(
                            source.name,
                            response.output.amount,
                            response.output.unit,
                            query.websiteURL,
                            Date(),
                            progressPercentage: nil
                        )
                    )
                }
            }
        }
    }

    private func performOnQueue(_ work: @escaping () -> Void) {
        // Refresh can be requested from another coordinator's queue. Avoid a
        // second hop when already on the owner queue so FIFO behavior stays
        // identical for the existing composition-root refresh path.
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.async { work() }
        }
    }

    private func updateQuickSwitchSummary(
        providerID: String,
        payload: QuickSwitchSummaryPayload
    ) {
        quickSwitchSummaryLock.lock()
        let previous = quickSwitchSummaryPayloads[providerID]
        guard previous != payload else {
            quickSwitchSummaryLock.unlock()
            return
        }
        quickSwitchSummaryPayloads[providerID] = payload
        quickSwitchSummaryLock.unlock()
        actions.quickSwitchSummaryChanged(providerID)
    }

    private func fetchBalance(
        providerID: String,
        providerName: String,
        query: BalanceQuery,
        client: AssistantClient
    ) {
        guard balanceAPIClient.fetchBalance(
            query: query,
            client: client,
            providerID: providerID,
            completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                let identity = ProviderBalanceProgressIdentity(
                    client: client,
                    providerID: providerID,
                    query: query
                )
                let progressResult = self.balanceProgressStore.update(
                    amount: response.output.amount,
                    unit: response.output.unit,
                    identity: identity
                )
                guard case .success(let progressPercentage) = progressResult else {
                    if case .failure(let error) = progressResult {
                        self.renderBalanceError(
                            providerID: providerID,
                            providerName: providerName,
                            reason: error.userVisibleReason(language: AppLanguage.resolved),
                            client: client
                        )
                    }
                    return
                }
                self.updateQuickSwitchSummary(
                    providerID: providerID,
                    payload: .formatted(Self.formatBalanceSummary(response.output.amount, unit: response.output.unit))
                )
                let balanceSnapshot = Snapshot.balance(
                    providerName,
                    response.output.amount,
                    response.output.unit,
                    query.websiteURL,
                    Date(),
                    progressPercentage: progressPercentage
                )
                self.renderForCurrentProvider(
                    balanceSnapshot,
                    providerID: providerID,
                    client: client
                )
            case .failure(.nonHTTPS):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: tr(.keyProviderRefreshCoordinatorTheBalanceEndpointIsNotHttps), client: client)
            case .failure(.transport(let error)):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: Self.localizedBalanceNetworkErrorReason(error, language: AppLanguage.resolved), client: client)
            case .failure(.httpStatus):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: tr(.keyProviderRefreshCoordinatorTheBalanceEndpointReturnedAnError), client: client)
            case .failure(.unsupportedFormat):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: tr(.keyProviderRefreshCoordinatorUnrecognizedBalanceFormat), client: client)
            case .failure(.invalidJSON):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: tr(.keyProviderRefreshCoordinatorTheBalanceResponseCouldNotBeParsed), client: client)
            }
            }
        ) else {
            return
        }
    }

    private func fetchOfficialQuota(providerID: String, providerName: String, client: AssistantClient) {
        if let demoSnapshot = DevelopmentLunaReserveDemo.snapshot(providerName: providerName)
            ?? DevelopmentBankedResetDemo.snapshot(providerName: providerName) {
            renderForCurrentProvider(
                demoSnapshot,
                providerID: providerID,
                client: client
            )
            return
        }
        // Freeze the account before transport starts. Never assign a late
        // response to the auth profile that happens to be current on arrival.
        let credentials = client == .codex ? officialQuotaClient.codexRequestCredentials() : nil
        let accountKey = credentials?.accountKey
        officialQuotaClient.fetchQuota(
            client: client,
            providerID: providerID,
            requestCredentials: credentials
        ) { [weak self] result in
            guard let self else { return }
            self.performOnQueue {
                guard client != .codex || self.officialQuotaClient.codexRequestCredentials() == credentials else { return }
                switch result {
                case .success(let response):
                    if client == .codex, let accountKey {
                        self.recordCodexQuotaEvidence(providerID: providerID, accountKey: accountKey, windows: response.output.windows)
                    }
                    self.updateQuickSwitchSummary(
                        providerID: providerID,
                        payload: .officialWindows(response.output.windows)
                    )
                    let renderOfficial: (CodexBankedReset?, CodexResetForecast) -> Void = { bankedReset, forecast in
                        guard client != .codex || self.officialQuotaClient.codexRequestCredentials() == credentials else { return }
                        let resolvedForecast = self.resolveCodexResetObservation(
                            providerID: providerID,
                            windows: response.output.windows,
                            forecast: forecast,
                            accountKey: accountKey,
                            client: client
                        )
                        self.renderForCurrentProvider(
                            .official(
                                providerName,
                                response.output.remaining,
                                response.output.label,
                                response.output.reset,
                                Date(),
                                windows: response.output.windows,
                                lunaReserve: response.output.lunaReserve,
                                bankedReset: bankedReset,
                                resetForecast: resolvedForecast
                            ),
                            providerID: providerID,
                            client: client,
                            isCurrentRequest: { client != .codex || self.officialQuotaClient.codexRequestCredentials() == credentials }
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
                            guard client != .codex || self.officialQuotaClient.codexRequestCredentials() == credentials else { return }
                            guard client == .codex, bankedReset != nil || self.cachedCodexResetForecast != nil else {
                                renderOfficial(bankedReset, cachedForecast)
                                return
                            }
                            self.provideCodexResetForecast { forecast in
                                renderOfficial(bankedReset, forecast)
                            }
                        }
                    }
                    if client == .codex && response.output.bankedResetNeedsCreditList {
                        self.officialQuotaClient.fetchRateLimitResetCredits(storedAccessToken: credentials?.accessToken, now: self.now()) { creditsResult in
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
                    self.renderOfficialError(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr(.keyProviderRefreshCoordinatorOfficialValueLocalSignInCredentialsWereNotFound, arguments: [String(describing: client.displayName)]),
                        client: client,
                        isCurrentRequest: { client != .codex || self.officialQuotaClient.codexRequestCredentials() == credentials }
                    )
                case .failure(.transport(let error)):
                    self.renderOfficialError(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr(.keyProviderRefreshCoordinatorOfficialValueValue, arguments: [String(describing: client.displayName), String(describing: error.localizedDescription)]),
                        client: client,
                        isCurrentRequest: { client != .codex || self.officialQuotaClient.codexRequestCredentials() == credentials }
                    )
                case .failure:
                    self.renderOfficialError(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr(.keyProviderRefreshCoordinatorOfficialValueTheQuotaEndpointReturnedAnError, arguments: [String(describing: client.displayName)]),
                        client: client,
                        isCurrentRequest: { client != .codex || self.officialQuotaClient.codexRequestCredentials() == credentials }
                    )
                }
            }
        }
    }

    /// Official quota evidence is captured before any forecast/credit transport.
    /// The journal is account-local and never by itself publishes a reset status.
    private func recordCodexQuotaEvidence(providerID: String, accountKey: String, windows: [OfficialQuotaWindow]) {
        guard let sample = CodexResetQuotaSample.make(from: windows) else { return }
        let key = observationCacheKey(providerID: providerID, accountKey: accountKey)
        var evidence = codexQuotaEvidence[key]
            ?? codexResetObservationStore.loadQuotaEvidence(providerID: providerID, accountKey: accountKey)
            ?? CodexResetObservation()
        if let previous = evidence.previousSample, previous.sevenDayResetAt <= now() {
            evidence = CodexResetObservation()
        }
        evidence.observe(sample, now: now())
        codexQuotaEvidence[key] = evidence
        codexResetObservationStore.saveQuotaEvidence(providerID: providerID, accountKey: accountKey, evidence: evidence)
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
            resetCodexQuotaEvidenceBaseline(providerID: providerID, accountKey: accountKey, windows: windows, clearOnMissingSample: true)
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
        if durable, priorEntry == nil, let pending = codexQuotaEvidence[cacheKey] {
            // A previously known episode always wins over unassigned evidence.
            // Expired quota cycles are discarded when recording; publication time
            // prevents an earlier reset from being attached to a later signal.
            let afterPublication = pending.detectedAt.map { detected in
                signal.publishedAt.map { detected >= $0 } ?? true
            } ?? true
            if afterPublication { seed = pending }
        }
        var entry = priorEntry ?? (episodeKey: episodeKey, observation: seed)
        if entry.episodeKey != episodeKey {
            entry = (episodeKey: episodeKey, observation: CodexResetObservation())
        }
        if let sample = CodexResetQuotaSample.make(from: windows) {
            var observation = entry.observation
            observation.observe(sample, now: now())
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
        resetCodexQuotaEvidenceBaseline(providerID: providerID, accountKey: accountKey, windows: windows)
        return forecast.applyingOfficialResetObservation(entry.observation.state)
    }

    private func observationCacheKey(providerID: String, accountKey: String) -> String {
        providerID + "|" + accountKey
    }

    private func renderOfficialError(
        providerID: String,
        providerName: String,
        reason: String,
        client: AssistantClient,
        isCurrentRequest: @escaping () -> Bool = { true }
    ) {
        renderForCurrentProvider(
            .providerError(providerName, reason: reason, cachedBalance: nil),
            providerID: providerID,
            client: client,
            isCurrentRequest: isCurrentRequest
        )
    }

    private func provideCodexResetForecast(
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

            if let cached = self.cachedCodexResetForecast {
                completion(cached.forecast.markingCached())
            } else {
                completion(.unavailable)
            }

            if !self.forecastRequestInFlight,
               let attempted = self.lastForecastAttempt,
               now.timeIntervalSince(attempted) < Self.codexResetForecastRetryInterval {
                return
            }
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
        isCurrentRequest: @escaping () -> Bool = { true }
    ) {
        queue.async { [weak self] in
            guard let self, isCurrentRequest(), self.repository.loadCurrent(appType: client.appType)?.id == providerID else { return }
            if next.kind == .balance {
                self.providerBalanceSnapshots.store(next, clientID: client.rawValue, providerID: providerID)
            }
            if next.kind == .official || next.kind == .balance {
                self.actions.notificationSnapshot?(client, providerID, next)
            }
            DispatchQueue.main.async {
                guard isCurrentRequest() else { return }
                if next.kind == .official || next.kind == .balance {
                    self.actions.storeClientSnapshot(client, providerID, next)
                }
                guard self.actions.isActiveClient(client) else { return }
                guard self.actions.currentProvider(client)?.id == providerID else { return }
                self.actions.render(next)
            }
        }
    }

    private func renderBalanceError(providerID: String, providerName: String, reason: String, client: AssistantClient) {
        queue.async { [weak self] in
            guard let self, self.repository.loadCurrent(appType: client.appType)?.id == providerID else { return }
            let next = self.providerBalanceSnapshots.errorSnapshot(
                clientID: client.rawValue,
                providerID: providerID,
                providerName: providerName,
                reason: reason
            )
            DispatchQueue.main.async {
                guard self.actions.isActiveClient(client) else { return }
                guard self.actions.currentProvider(client)?.id == providerID else { return }
                self.actions.render(next)
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
