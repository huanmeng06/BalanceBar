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
final class OpenCodexRefreshCoordinator {
    private let repository: CCSwitchRepository
    private let officialQuotaClient: OfficialQuotaClient
    private let balanceAPIClient: BalanceAPIClient
    private let openCodexRepository: OpenCodexRepository
    private let queue: DispatchQueue
    private let actions: OpenCodexRefreshActions
    private var stateByProvider: [String: OpenCodexRuntimeState] = [:]
    private var candidateByProvider: [String: OpenCodexEndpointCandidate] = [:]
    private(set) var state: (providerID: String, value: OpenCodexRuntimeState)?
    private(set) var cards: [OpenCodexModelCard] = []
    private var plans: [OpenCodexCardPlan] = []
    private var cardData: [OpenCodexCardSource: OpenCodexCardData] = [:]
    private var refreshCoordinator = OpenCodexCardRefreshCoordinator()
    private var requestsInFlight: Set<OpenCodexCardSource> = []

    init(
        repository: CCSwitchRepository,
        officialQuotaClient: OfficialQuotaClient,
        balanceAPIClient: BalanceAPIClient,
        openCodexRepository: OpenCodexRepository,
        queue: DispatchQueue,
        actions: OpenCodexRefreshActions
    ) {
        self.repository = repository
        self.officialQuotaClient = officialQuotaClient
        self.balanceAPIClient = balanceAPIClient
        self.openCodexRepository = openCodexRepository
        self.queue = queue
        self.actions = actions
    }

    var currentCandidate: OpenCodexEndpointCandidate? {
        state?.value.candidate
            ?? repository.loadCurrent(appType: AssistantClient.codex.appType)?.openCodexCandidate
            ?? repository.loadSummarySources(appType: AssistantClient.codex.appType).compactMap(\.openCodexCandidate).first
    }

    func isConfirmed(providerID: String, candidate: OpenCodexEndpointCandidate) -> Bool {
        candidateByProvider[providerID] == candidate
    }

    func clear() {
        plans = []
        cardData = [:]
        refreshCoordinator.reset()
        requestsInFlight.removeAll()
        state = nil
        cards = []
        actions.setState("", nil)
        actions.setCards([])
    }

    func switchPreference(_ preference: OpenCodexPreference, providerID: String, oldState: OpenCodexRuntimeState) {
        queue.async { [weak self] in
            guard let self else { return }
            self.openCodexRepository.select(preference, from: oldState) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard self.actions.activeClient() == .codex,
                          self.repository.loadCurrent(appType: AssistantClient.codex.appType)?.id == providerID else { return }
                    switch result {
                    case .success(let next):
                        self.publishState(providerID: providerID, state: next)
                        self.prepareCards(providerID: providerID, state: next, force: true)
                        self.render(providerID: providerID, providerName: self.repository.loadCurrent(appType: AssistantClient.codex.appType)?.name ?? providerID, state: next, client: .codex)
                    case .failure(let error):
                        let message = error.message(for: AppLanguage.resolved)
                        let status = tr("切换失败：\(message)", "Switch failed: \(message)", "切換失敗：\(message)", "切り替えに失敗しました：\(message)")
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
        openCodexRepository.readState(for: candidate) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.actions.activeClient() == client,
                      self.repository.loadCurrent(appType: client.appType)?.id == providerID else { return }
                switch result {
                case .notRecognized:
                    self.candidateByProvider.removeValue(forKey: providerID)
                    self.stateByProvider.removeValue(forKey: providerID)
                    self.clear()
                    guard let current = self.repository.loadCurrent(appType: client.appType) else { return }
                    self.actions.refreshStandard(current, client, reason, switched)
                case .unavailable:
                    guard let previous = self.stateByProvider[providerID] else {
                        self.clear()
                        guard let current = self.repository.loadCurrent(appType: client.appType) else { return }
                        self.actions.refreshStandard(current, client, reason, switched)
                        return
                    }
                    let unavailable = self.unavailableState(from: previous)
                    self.stateByProvider[providerID] = unavailable
                    self.publishState(providerID: providerID, state: unavailable)
                    self.publishCardsUnavailable(reason: tr("OpenCodex 管理接口不可用", "OpenCodex management API is unavailable", "OpenCodex 管理介面不可用", "OpenCodex 管理 API を利用できません"))
                    self.render(providerID: providerID, providerName: providerName, state: unavailable, client: client)
                case .recognized(let recognized):
                    self.candidateByProvider[providerID] = candidate
                    self.stateByProvider[providerID] = recognized
                    self.publishState(providerID: providerID, state: recognized)
                    self.prepareCards(providerID: providerID, state: recognized, force: reason.forcesOpenCodexCardSources || switched)
                    self.render(providerID: providerID, providerName: providerName, state: recognized, client: client)
                }
            }
        }
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

    private func prepareCards(providerID: String, state: OpenCodexRuntimeState, force: Bool) {
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
                ?? (state.managementAvailable ? .loading(category: plan.source.category) : .unavailable(category: plan.source.category, reason: tr("OpenCodex 管理接口不可用", "OpenCodex management API is unavailable", "OpenCodex 管理介面不可用", "OpenCodex 管理 API を利用できません")))
        }
        cardData = nextData
        publishCards()
        guard state.managementAvailable else { return }
        for source in refreshPlan.dueSources {
            guard let generation = refreshCoordinator.generation(for: source.source) else { continue }
            requestsInFlight.insert(source.source)
            switch source.source {
            case .official:
                fetchOfficialCard(providerID: providerID, generation: generation)
            case .balance(let sourceID):
                guard let summary = sources.first(where: { $0.id == sourceID }), let query = summary.query else {
                    updateCard(providerID: providerID, generation: generation, source: source.source, data: .unavailable(category: .balance, reason: tr("余额来源配置不完整", "The balance source configuration is incomplete", "餘額來源設定不完整", "残高ソースの設定が不完全です")))
                    continue
                }
                _ = balanceAPIClient.fetchBalance(query: query, client: .codex, providerID: "opencodex-card:\(sourceID)") { [weak self] result in
                    guard let self else { return }
                    let data: OpenCodexCardData
                    if case .success(let response) = result {
                        data = .balance(amount: response.output.amount, unit: response.output.unit, websiteURL: Self.secureWebsiteURL(summary.websiteURL ?? query.websiteURL), updatedAt: Date())
                    } else if case .failure(.nonHTTPS) = result {
                        data = .unavailable(category: .balance, reason: tr("余额不可用：余额接口不是 HTTPS", "Balance unavailable: the balance endpoint is not HTTPS", "餘額不可用：餘額介面不是 HTTPS", "残高を利用できません：残高エンドポイントが HTTPS ではありません"))
                    } else {
                        data = .unavailable(category: .balance, reason: tr("余额不可用：无法读取上游余额", "Balance unavailable: the upstream balance could not be read", "餘額不可用：無法讀取上游餘額", "残高を利用できません：上流の残高を読み取れません"))
                    }
                    self.queue.async { self.updateCard(providerID: providerID, generation: generation, source: source.source, data: data) }
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

    private func fetchOfficialCard(providerID: String, generation: UUID) {
        officialQuotaClient.fetchQuota(client: .codex, providerID: providerID, storedAccessToken: nil) { [weak self] result in
            guard let self else { return }
            let data: OpenCodexCardData
            switch result {
            case .success(let response):
                data = .official(remaining: response.output.remaining, label: response.output.label, reset: response.output.reset, updatedAt: Date())
            case .failure(.missingCredentials):
                data = .unavailable(category: .quota, reason: tr("额度不可用：未找到官方登录态", "Quota unavailable: official sign-in credentials were not found", "額度不可用：找不到官方登入狀態", "クォータを利用できません：公式ログイン情報が見つかりません"))
            case .failure:
                data = .unavailable(category: .quota, reason: tr("额度不可用：官方额度接口暂时不可用", "Quota unavailable: the official quota endpoint is temporarily unavailable", "額度不可用：官方額度介面暫時不可用", "クォータを利用できません：公式クォータエンドポイントが一時的に利用できません"))
            }
            self.queue.async { self.updateCard(providerID: providerID, generation: generation, source: .official, data: data) }
        }
    }

    private func updateCard(providerID: String, generation: UUID, source: OpenCodexCardSource, data: OpenCodexCardData) {
        guard refreshCoordinator.generation(for: source) == generation,
              let visible = refreshCoordinator.store(data, for: source, generation: generation) else { return }
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
        if !state.managementAvailable { return tr("管理接口不可用，等待 OpenCodex 恢复", "Management API unavailable; waiting for OpenCodex", "管理介面不可用，等待 OpenCodex 恢復", "管理 API を利用できません。OpenCodex の復旧を待機中") }
        if !state.preferenceDataAvailable { return tr("暂未读取到 OpenCodex 偏好", "OpenCodex preferences are not available yet", "尚未讀取到 OpenCodex 偏好", "OpenCodex の設定はまだ読み込まれていません") }
        if state.preferences.isEmpty { return tr("没有配置 OpenCodex 子项", "No OpenCodex preferences configured", "未設定 OpenCodex 子項目", "OpenCodex の設定がありません") }
        if let current = state.currentSelector { return tr("当前：\(current)", "Current: \(current)", "目前：\(current)", "現在：\(current)") }
        return tr("已读取 OpenCodex 偏好", "OpenCodex preferences loaded", "已讀取 OpenCodex 偏好", "OpenCodex の設定を読み込みました")
    }

    private func unavailableState(from state: OpenCodexRuntimeState) -> OpenCodexRuntimeState {
        OpenCodexRuntimeState(candidate: state.candidate, defaultProvider: state.defaultProvider, providerDefaultModels: state.providerDefaultModels, providers: state.providers, chosenSelectors: state.chosenSelectors, availableSelectors: state.availableSelectors, preferences: state.preferences, managementAvailable: false, preferenceDataAvailable: state.preferenceDataAvailable)
    }

    private static func secureWebsiteURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil, host != "localhost", host != "::1", host != "127.0.0.1", !host.hasPrefix("127.") else { return nil }
        return url
    }
}
