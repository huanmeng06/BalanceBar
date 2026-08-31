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

struct ProviderRefreshActions {
    let currentProvider: (AssistantClient) -> CCSwitchProvider?
    let isActiveClient: (AssistantClient) -> Bool
    let render: (Snapshot) -> Void
    let storeClientSnapshot: (AssistantClient, String, Snapshot) -> Void
    let updateQuickSwitchSummary: (String, String) -> Void
    let isOpenCodexConfirmed: (String) -> Bool
}

/// Owns standard Provider balance/quota requests, request cadence, quick
/// switch summaries, and Provider-balance fallback snapshots. It has no AppKit
/// page/window ownership; results leave through explicit value callbacks.
final class ProviderRefreshCoordinator {
    private let repository: CCSwitchRepository
    private let officialQuotaClient: OfficialQuotaClient
    private let balanceAPIClient: BalanceAPIClient
    private let balanceProgressStore: ProviderBalanceProgressStore
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let now: () -> Date
    private let actions: ProviderRefreshActions
    // Cadence timestamps are owned by `queue`; public entry points never read
    // or write them until their work reaches that serial boundary.
    private var lastBalanceFetch: Date?
    private var lastOfficialFetch: Date?
    private var lastQuickSwitchFetch: Date?
    private var quickSwitchSummaryLock = NSLock()
    private var quickSwitchSummaries: [String: String] = [:]
    private var providerBalanceSnapshots = ProviderBalanceSnapshotCache()

    init(
        repository: CCSwitchRepository,
        officialQuotaClient: OfficialQuotaClient,
        balanceAPIClient: BalanceAPIClient = BalanceAPIClient(),
        balanceProgressStore: ProviderBalanceProgressStore = ProviderBalanceProgressStore(),
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.provider-refresh"),
        actions: ProviderRefreshActions,
        now: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.officialQuotaClient = officialQuotaClient
        self.balanceAPIClient = balanceAPIClient
        self.balanceProgressStore = balanceProgressStore
        self.queue = queue
        self.now = now
        self.actions = actions
        queue.setSpecific(key: queueKey, value: ())
    }

    func quickSwitchSummariesSnapshot() -> [String: String] {
        quickSwitchSummaryLock.lock()
        defer { quickSwitchSummaryLock.unlock() }
        return quickSwitchSummaries
    }

    func resetCadence() {
        performOnQueue { [weak self] in
            guard let self else { return }
            self.lastBalanceFetch = nil
            self.lastOfficialFetch = nil
            self.lastQuickSwitchFetch = nil
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
            guard current.isOfficial else {
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
            } else if current.isOfficial, client != .claude {
                self.fetchOfficialQuota(providerID: current.id, providerName: current.name, client: client)
            }
        }
    }

    func refreshQuickSwitchSummaries(force: Bool, for requestedClient: AssistantClient? = nil) {
        let client = requestedClient ?? .codex
        queue.async { [weak self] in
            guard let self else { return }
            let currentDate = self.now()
            let due = self.lastQuickSwitchFetch.map { currentDate.timeIntervalSince($0) >= 60 } ?? true
            guard force || due else { return }
            self.lastQuickSwitchFetch = currentDate
            for source in self.repository.loadSummarySources(appType: client.appType) {
                if client == .codex,
                   source.openCodexCandidate != nil,
                   self.actions.isOpenCodexConfirmed(source.id) { continue }
                if source.isOfficial {
                    if client == .claude { continue }
                    self.officialQuotaClient.fetchQuota(
                        client: client,
                        providerID: source.id,
                        storedAccessToken: source.officialAccessToken
                    ) { [weak self] result in
                        guard let self, case .success(let response) = result else { return }
                        self.updateQuickSwitchSummary(
                            providerID: source.id,
                            text: "\(Int(response.output.remaining))% / \(response.output.daysText)"
                        )
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
                        text: Self.formatBalanceSummary(response.output.amount, unit: response.output.unit)
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

    private func updateQuickSwitchSummary(providerID: String, text: String) {
        quickSwitchSummaryLock.lock()
        let previous = quickSwitchSummaries[providerID]
        guard previous != text else {
            quickSwitchSummaryLock.unlock()
            return
        }
        quickSwitchSummaries[providerID] = text
        quickSwitchSummaryLock.unlock()
        actions.updateQuickSwitchSummary(providerID, text)
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
                    text: Self.formatBalanceSummary(response.output.amount, unit: response.output.unit)
                )
                self.renderForCurrentProvider(
                    .balance(
                        providerName,
                        response.output.amount,
                        response.output.unit,
                        query.websiteURL,
                        Date(),
                        progressPercentage: progressPercentage
                    ),
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
        if let demoSnapshot = DevelopmentLunaReserveDemo.snapshot(providerName: providerName) {
            renderForCurrentProvider(
                demoSnapshot,
                providerID: providerID,
                client: client
            )
            return
        }
        officialQuotaClient.fetchQuota(client: client, providerID: providerID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.updateQuickSwitchSummary(providerID: providerID, text: "\(Int(response.output.remaining))% / \(response.output.daysText)")
                self.renderForCurrentProvider(
                    .official(
                        providerName,
                        response.output.remaining,
                        response.output.label,
                        response.output.reset,
                        Date(),
                        windows: response.output.windows,
                        lunaReserve: response.output.lunaReserve
                    ),
                    providerID: providerID,
                    client: client
                )
            case .failure(.missingCredentials):
                self.renderOfficialError(
                    providerID: providerID,
                    providerName: providerName,
                    reason: tr(.keyProviderRefreshCoordinatorOfficialValueLocalSignInCredentialsWereNotFound, arguments: [String(describing: client.displayName)]),
                    client: client
                )
            case .failure(.transport(let error)):
                self.renderOfficialError(
                    providerID: providerID,
                    providerName: providerName,
                    reason: tr(.keyProviderRefreshCoordinatorOfficialValueValue, arguments: [String(describing: client.displayName), String(describing: error.localizedDescription)]),
                    client: client
                )
            case .failure:
                self.renderOfficialError(
                    providerID: providerID,
                    providerName: providerName,
                    reason: tr(.keyProviderRefreshCoordinatorOfficialValueTheQuotaEndpointReturnedAnError, arguments: [String(describing: client.displayName)]),
                    client: client
                )
            }
        }
    }

    private func renderOfficialError(
        providerID: String,
        providerName: String,
        reason: String,
        client: AssistantClient
    ) {
        renderForCurrentProvider(
            .providerError(providerName, reason: reason, cachedBalance: nil),
            providerID: providerID,
            client: client
        )
    }

    private func renderForCurrentProvider(_ next: Snapshot, providerID: String, client: AssistantClient) {
        queue.async { [weak self] in
            guard let self, self.repository.loadCurrent(appType: client.appType)?.id == providerID else { return }
            if next.kind == .balance {
                self.providerBalanceSnapshots.store(next, clientID: client.rawValue, providerID: providerID)
            }
            DispatchQueue.main.async {
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
