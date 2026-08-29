import Foundation

struct OpenCodexRefreshActions {
    let activeClient: () -> AssistantClient
    let currentProvider: (AssistantClient) -> CCSwitchProvider?
    let setState: (String, OpenCodexRuntimeState?) -> Void
    let setCards: ([OpenCodexModelCard]) -> Void
    let refreshMenu: () -> Void
    let render: (Snapshot, String, AssistantClient) -> Void
    let refreshStandard: (CCSwitchProvider, AssistantClient, BalanceRefreshReason, Bool) -> Void
}

/// Owns OpenCodex recognition, preference switching, card planning and card
/// requests. The UI receives state/cards through value callbacks; this type
/// does not know about Dashboard or status-item views.
///
/// All mutable state is owned by `queue`. Synchronous read accessors marshal
/// onto that queue so callers cannot observe or mutate partially updated
/// recognition state.
final class OpenCodexRefreshCoordinator {
    private let repository: CCSwitchRepository
    private let officialQuotaClient: OfficialQuotaClient
    private let balanceAPIClient: BalanceAPIClient
    private let balanceProgressStore: ProviderBalanceProgressStore
    private let openCodexRepository: OpenCodexRepository
    private let queue: DispatchQueue
    private let actions: OpenCodexRefreshActions
    private let queueKey = DispatchSpecificKey<Void>()
    private var stateByProvider: [String: OpenCodexRuntimeState] = [:]
    private var candidateByProvider: [String: OpenCodexEndpointCandidate] = [:]
    private var state: (providerID: String, value: OpenCodexRuntimeState)?
    private var cards: [OpenCodexModelCard] = []
    private var plans: [OpenCodexCardPlan] = []
    private var cardData: [OpenCodexCardSource: OpenCodexCardData] = [:]
    private var refreshCoordinator = OpenCodexCardRefreshCoordinator()
    private var requestsInFlight: Set<OpenCodexCardSource> = []
    private var generation: UInt64 = 0
    private var stateOperationGeneration: UInt64 = 0
    private var isInvalidated = false

    init(
        repository: CCSwitchRepository,
        officialQuotaClient: OfficialQuotaClient,
        balanceAPIClient: BalanceAPIClient,
        balanceProgressStore: ProviderBalanceProgressStore = ProviderBalanceProgressStore(),
        openCodexRepository: OpenCodexRepository,
        queue: DispatchQueue,
        actions: OpenCodexRefreshActions
    ) {
        self.repository = repository
        self.officialQuotaClient = officialQuotaClient
        self.balanceAPIClient = balanceAPIClient
        self.balanceProgressStore = balanceProgressStore
        self.openCodexRepository = openCodexRepository
        self.queue = queue
        self.actions = actions
        queue.setSpecific(key: queueKey, value: ())
    }

    var currentCandidate: OpenCodexEndpointCandidate? {
        syncOnQueue {
            guard !isInvalidated else { return nil }
            return state?.value.candidate
                ?? repository.loadCurrent(appType: AssistantClient.codex.appType)?.openCodexCandidate
                ?? repository.loadSummarySources(appType: AssistantClient.codex.appType).compactMap(\.openCodexCandidate).first
        }
    }

    func isConfirmed(providerID: String, candidate: OpenCodexEndpointCandidate) -> Bool {
        syncOnQueue {
            !isInvalidated && candidateByProvider[providerID] == candidate
        }
    }

    func clear() {
        syncOnQueue {
            guard !isInvalidated else { return }
            clearState(notify: true)
        }
    }

    /// Invalidates all work owned by this coordinator before the application
    /// tears down its other services. Completion handlers may still arrive
    /// from the underlying clients, but they can no longer publish state.
    func teardown() {
        syncOnQueue {
            guard !isInvalidated else { return }
            isInvalidated = true
            clearState(notify: false)
        }
    }

    func switchPreference(_ preference: OpenCodexPreference, providerID: String, oldState: OpenCodexRuntimeState) {
        queue.async { [weak self] in
            guard let self,
                  let context = self.beginStateOperation() else { return }
            self.openCodexRepository.select(preference, from: oldState) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard self.isCurrent(context),
                          self.actions.activeClient() == .codex,
                          self.actions.currentProvider(.codex)?.id == providerID else { return }
                    switch result {
                    case .success(let next):
                        self.publishState(providerID: providerID, state: next)
                        self.prepareCards(
                            providerID: providerID,
                            state: next,
                            force: true,
                            lifecycleGeneration: context.lifecycleGeneration,
                            stateOperationGeneration: context.stateOperationGeneration
                        )
                        self.render(
                            providerID: providerID,
                            providerName: self.actions.currentProvider(.codex)?.name ?? providerID,
                            state: next,
                            client: .codex
                        )
                    case .failure(let error):
                        let message = error.message(for: AppLanguage.resolved)
                        let status = tr(.keyOpenCodexRefreshCoordinatorSwitchFailedValue, arguments: [String(describing: message)])
                        self.actions.render(.openCodex(providerID, selector: oldState.currentSelector, status: status, Date()), providerID, .codex)
                    }
                }
            }
        }
    }

    func refresh(
        providerID: String,
        providerName: String,
        candidate: OpenCodexEndpointCandidate,
        client: AssistantClient,
        reason: BalanceRefreshReason,
        switched: Bool
    ) {
        queue.async { [weak self] in
            guard let self,
                  let context = self.beginStateOperation() else { return }
            self.openCodexRepository.readState(for: candidate) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard self.isCurrent(context),
                          self.actions.activeClient() == client,
                          self.actions.currentProvider(client)?.id == providerID else { return }
                    switch result {
                    case .notRecognized:
                        self.clearState(notify: true)
                        guard let current = self.actions.currentProvider(client) else { return }
                        self.actions.refreshStandard(current, client, reason, switched)
                    case .unavailable:
                        guard let previous = self.stateByProvider[providerID] else {
                            self.clearState(notify: true)
                            guard let current = self.actions.currentProvider(client) else { return }
                            self.actions.refreshStandard(current, client, reason, switched)
                            return
                        }
                        let unavailable = self.unavailableState(from: previous)
                        self.stateByProvider[providerID] = unavailable
                        self.publishState(providerID: providerID, state: unavailable)
                        self.publishCardsUnavailable(reason: tr(.keyOpenCodexRefreshCoordinatorOpencodexManagementApiIsUnavailable))
                        self.render(providerID: providerID, providerName: providerName, state: unavailable, client: client)
                    case .recognized(let recognized):
                        self.candidateByProvider[providerID] = candidate
                        self.stateByProvider[providerID] = recognized
                        self.publishState(providerID: providerID, state: recognized)
                        self.prepareCards(
                            providerID: providerID,
                            state: recognized,
                            force: reason.forcesOpenCodexCardSources || switched,
                            lifecycleGeneration: context.lifecycleGeneration,
                            stateOperationGeneration: context.stateOperationGeneration
                        )
                        self.render(providerID: providerID, providerName: providerName, state: recognized, client: client)
                    }
                }
            }
        }
    }

    private struct StateOperationContext {
        let lifecycleGeneration: UInt64
        let stateOperationGeneration: UInt64
    }

    private func beginStateOperation() -> StateOperationContext? {
        guard !isInvalidated else { return nil }
        stateOperationGeneration &+= 1
        return StateOperationContext(
            lifecycleGeneration: generation,
            stateOperationGeneration: stateOperationGeneration
        )
    }

    private func isCurrent(_ context: StateOperationContext) -> Bool {
        !isInvalidated
            && generation == context.lifecycleGeneration
            && stateOperationGeneration == context.stateOperationGeneration
    }

    private func clearState(notify: Bool) {
        generation &+= 1
        stateOperationGeneration &+= 1
        stateByProvider.removeAll()
        candidateByProvider.removeAll()
        plans = []
        cardData = [:]
        refreshCoordinator.reset()
        requestsInFlight.removeAll()
        state = nil
        cards = []
        guard notify else { return }
        actions.setState("", nil)
        actions.setCards([])
    }

    private func syncOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return work()
        }
        return queue.sync(execute: work)
    }

    private func publishState(providerID: String, state: OpenCodexRuntimeState?) {
        self.state = state.map { (providerID, $0) }
        actions.setState(providerID, state)
    }

    private func render(providerID: String, providerName: String, state: OpenCodexRuntimeState, client: AssistantClient) {
        actions.render(
            .openCodex(providerName, selector: state.currentSelector, status: statusText(for: state), Date()),
            providerID,
            client
        )
    }

    private func prepareCards(
        providerID: String,
        state: OpenCodexRuntimeState,
        force: Bool,
        lifecycleGeneration: UInt64,
        stateOperationGeneration: UInt64
    ) {
        let sources = repository.loadSummarySources(appType: AssistantClient.codex.appType)
        plans = OpenCodexCardPlanner.plans(state: state, sources: sources)
        let refreshSources = makeRefreshSources(plans: plans, state: state, sources: sources)
        let refreshPlan = refreshCoordinator.plan(
            sources: refreshSources,
            now: Date(),
            force: force,
            allowRequests: state.managementAvailable,
            inFlight: requestsInFlight
        )
        let activeSources = Set(refreshSources.map(\.source))
        requestsInFlight.formIntersection(activeSources)
        requestsInFlight.subtract(refreshPlan.configurationChanged)
        var nextData: [OpenCodexCardSource: OpenCodexCardData] = [:]
        for plan in plans {
            if case .unavailable = plan.source { continue }
            nextData[plan.source] = refreshCoordinator.visibleData(for: plan.source)
                ?? (state.managementAvailable ? .loading(category: plan.source.category) : .unavailable(category: plan.source.category, reason: tr(.keyOpenCodexRefreshCoordinatorOpencodexManagementApiIsUnavailable2)))
        }
        cardData = nextData
        publishCards()
        guard state.managementAvailable else { return }
        for source in refreshPlan.dueSources {
            guard let generation = refreshCoordinator.generation(for: source.source) else { continue }
            requestsInFlight.insert(source.source)
            switch source.source {
            case .official:
                fetchOfficialCard(
                    providerID: providerID,
                    lifecycleGeneration: lifecycleGeneration,
                    stateOperationGeneration: stateOperationGeneration,
                    cardGeneration: generation
                )
            case .balance(let sourceID):
                guard let summary = sources.first(where: { $0.id == sourceID }), let query = summary.query else {
                    updateCard(
                        providerID: providerID,
                        lifecycleGeneration: lifecycleGeneration,
                        stateOperationGeneration: stateOperationGeneration,
                        cardGeneration: generation,
                        source: source.source,
                        data: .unavailable(category: .balance, reason: tr(.keyOpenCodexRefreshCoordinatorTheBalanceSourceConfigurationIsIncomplete))
                    )
                    continue
                }
                _ = balanceAPIClient.fetchBalance(query: query, client: .codex, providerID: "opencodex-card:\(sourceID)") { [weak self] result in
                    guard let self else { return }
                    let data: OpenCodexCardData
                    if case .success(let response) = result {
                        let identity = ProviderBalanceProgressIdentity(
                            client: .codex,
                            providerID: sourceID,
                            query: query
                        )
                        switch self.balanceProgressStore.update(
                            amount: response.output.amount,
                            unit: response.output.unit,
                            identity: identity
                        ) {
                        case .success(let progressPercentage):
                            data = .balance(
                                amount: response.output.amount,
                                unit: response.output.unit,
                                progressPercentage: progressPercentage,
                                websiteURL: Self.secureWebsiteURL(summary.websiteURL ?? query.websiteURL),
                                updatedAt: Date()
                            )
                        case .failure(let error):
                            data = .unavailable(
                                category: .balance,
                                reason: error.userVisibleReason(language: AppLanguage.resolved)
                            )
                        }
                    } else if case .failure(.nonHTTPS) = result {
                        data = .unavailable(category: .balance, reason: tr(.keyOpenCodexRefreshCoordinatorBalanceUnavailableTheBalanceEndpointIsNotHttps))
                    } else {
                        data = .unavailable(category: .balance, reason: tr(.keyOpenCodexRefreshCoordinatorBalanceUnavailableTheUpstreamBalanceCouldNotBeRead))
                    }
                    self.queue.async {
                        self.updateCard(
                            providerID: providerID,
                            lifecycleGeneration: lifecycleGeneration,
                            stateOperationGeneration: stateOperationGeneration,
                            cardGeneration: generation,
                            source: source.source,
                            data: data
                        )
                    }
                }
            case .unavailable:
                requestsInFlight.remove(source.source)
            }
        }
    }

    private func makeRefreshSources(plans: [OpenCodexCardPlan], state: OpenCodexRuntimeState, sources: [ProviderSummarySource]) -> [OpenCodexCardRefreshSource] {
        var result: [OpenCodexCardRefreshSource] = []
        var seen = Set<OpenCodexCardSource>()
        for plan in plans where seen.insert(plan.source).inserted {
            switch plan.source {
            case .official:
                result.append(.init(
                    source: .official,
                    interval: 60,
                    configurationFingerprint: officialCardFingerprint(plans: plans, state: state, sources: sources)
                ))
            case .balance(let sourceID):
                guard let summary = sources.first(where: { $0.id == sourceID }), let query = summary.query else { continue }
                result.append(.init(
                    source: plan.source,
                    interval: TimeInterval(max(query.intervalMinutes, 1) * 60),
                    configurationFingerprint: balanceCardFingerprint(summary: summary, query: query, state: state, plans: plans)
                ))
            case .unavailable: break
            }
        }
        return result
    }

    private func officialCardFingerprint(
        plans: [OpenCodexCardPlan],
        state: OpenCodexRuntimeState,
        sources: [ProviderSummarySource]
    ) -> String {
        let providers = plans.compactMap { plan in
            guard let descriptor = state.providers[plan.provider], descriptor.isOfficial else { return nil }
            return providerFingerprint(descriptor)
        }.joined(separator: ";")
        let sourceFingerprint = sources.filter(\.isOfficial).map {
            [$0.id, $0.name, $0.websiteURL?.absoluteString ?? "", $0.officialAccessToken.map { String($0.hashValue) } ?? "missing"].joined(separator: "|")
        }.joined(separator: ";")
        return "official:\(providers):\(sourceFingerprint)"
    }

    private func balanceCardFingerprint(
        summary: ProviderSummarySource,
        query: BalanceQuery,
        state: OpenCodexRuntimeState,
        plans: [OpenCodexCardPlan]
    ) -> String {
        let provider = plans.compactMap { plan in
            guard case .balance(let sourceID) = plan.source,
                  sourceID == summary.id,
                  let descriptor = state.providers[plan.provider] else { return nil }
            return providerFingerprint(descriptor)
        }.joined(separator: ";")
        return [
            summary.id, summary.name, query.url, String(query.intervalMinutes),
            summary.websiteURL?.absoluteString ?? query.websiteURL?.absoluteString ?? "",
            String(query.apiKey.hashValue), query.additionalHeaders.keys.sorted().joined(separator: ","),
            String(query.isRightCode), query.subscriptionPrefix, String(query.isNewAPI),
            String(describing: query.nativeBalanceProvider), provider
        ].joined(separator: "|")
    }

    private func providerFingerprint(_ descriptor: OpenCodexProviderDescriptor) -> String {
        [descriptor.id, descriptor.adapter, descriptor.authMode, descriptor.baseURL.absoluteString, descriptor.defaultModel ?? "", descriptor.models.joined(separator: ","), String(descriptor.isOfficial)].joined(separator: "|")
    }

    private func fetchOfficialCard(
        providerID: String,
        lifecycleGeneration: UInt64,
        stateOperationGeneration: UInt64,
        cardGeneration: UUID
    ) {
        officialQuotaClient.fetchQuota(client: .codex, providerID: providerID, storedAccessToken: nil) { [weak self] result in
            guard let self else { return }
            let data: OpenCodexCardData
            switch result {
            case .success(let response):
                if let window = response.output.representativeWindow {
                    data = .official(window: window, updatedAt: Date())
                } else {
                    data = .official(
                        remaining: response.output.remaining,
                        label: response.output.label,
                        reset: response.output.reset,
                        updatedAt: Date()
                    )
                }
            case .failure(.missingCredentials):
                data = .unavailable(category: .quota, reason: tr(.keyOpenCodexRefreshCoordinatorQuotaUnavailableOfficialSignInCredentialsWereNotFound))
            case .failure:
                data = .unavailable(category: .quota, reason: tr(.keyOpenCodexRefreshCoordinatorQuotaUnavailableTheOfficialQuotaEndpointIsTemporarilyUnavailable))
            }
            self.queue.async {
                self.updateCard(
                    providerID: providerID,
                    lifecycleGeneration: lifecycleGeneration,
                    stateOperationGeneration: stateOperationGeneration,
                    cardGeneration: cardGeneration,
                    source: .official,
                    data: data
                )
            }
        }
    }

    private func updateCard(
        providerID: String,
        lifecycleGeneration: UInt64,
        stateOperationGeneration: UInt64,
        cardGeneration: UUID,
        source: OpenCodexCardSource,
        data: OpenCodexCardData
    ) {
        guard !isInvalidated,
              self.generation == lifecycleGeneration,
              self.stateOperationGeneration == stateOperationGeneration,
              state?.providerID == providerID,
              refreshCoordinator.generation(for: source) == cardGeneration,
              let visible = refreshCoordinator.store(data, for: source, generation: cardGeneration) else { return }
        requestsInFlight.remove(source)
        cardData[source] = visible
        publishCards()
    }

    private func publishCards() {
        cards = OpenCodexCardPlanner.cards(plans: plans, data: cardData)
        actions.setCards(cards)
        actions.refreshMenu()
    }

    private func publishCardsUnavailable(reason: String) {
        for plan in plans {
            if case .unavailable = plan.source { continue }
            cardData[plan.source] = refreshCoordinator.visibleData(for: plan.source) ?? .unavailable(category: plan.source.category, reason: reason)
        }
        publishCards()
    }

    private func statusText(for state: OpenCodexRuntimeState) -> String {
        if !state.managementAvailable { return tr(.keyOpenCodexRefreshCoordinatorManagementApiUnavailableWaitingForOpencodex) }
        if !state.preferenceDataAvailable { return tr(.keyOpenCodexRefreshCoordinatorOpencodexPreferencesAreNotAvailableYet) }
        if state.preferences.isEmpty { return tr(.keyOpenCodexRefreshCoordinatorNoOpencodexPreferencesConfigured) }
        if let current = state.currentSelector { return tr(.keyOpenCodexRefreshCoordinatorCurrentValue, arguments: [String(describing: current)]) }
        return tr(.keyOpenCodexRefreshCoordinatorOpencodexPreferencesLoaded)
    }

    private func unavailableState(from state: OpenCodexRuntimeState) -> OpenCodexRuntimeState {
        OpenCodexRuntimeState(candidate: state.candidate, defaultProvider: state.defaultProvider, providerDefaultModels: state.providerDefaultModels, providers: state.providers, chosenSelectors: state.chosenSelectors, availableSelectors: state.availableSelectors, preferences: state.preferences, managementAvailable: false, preferenceDataAvailable: state.preferenceDataAvailable)
    }

    private static func secureWebsiteURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil, host != "localhost", host != "::1", host != "127.0.0.1", !host.hasPrefix("127.") else { return nil }
        return url
    }
}
