import Foundation

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
    private let queue: DispatchQueue
    private let actions: ProviderRefreshActions
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
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.provider-refresh"),
        actions: ProviderRefreshActions
    ) {
        self.repository = repository
        self.officialQuotaClient = officialQuotaClient
        self.balanceAPIClient = balanceAPIClient
        self.queue = queue
        self.actions = actions
    }

    func quickSwitchSummariesSnapshot() -> [String: String] {
        quickSwitchSummaryLock.lock()
        defer { quickSwitchSummaryLock.unlock() }
        return quickSwitchSummaries
    }

    func resetCadence() {
        lastBalanceFetch = nil
        lastOfficialFetch = nil
        lastQuickSwitchFetch = nil
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
            let due = lastOfficialFetch.map { Date().timeIntervalSince($0) >= 60 } ?? true
            guard forceBalance || switched || due else { return }
            lastOfficialFetch = Date()
            fetchOfficialQuota(providerID: current.id, providerName: current.name, client: client)
            return
        }

        let interval = TimeInterval(max(query.intervalMinutes, 1) * 60)
        let due = lastBalanceFetch.map { Date().timeIntervalSince($0) >= interval } ?? true
        guard forceBalance || switched || due else { return }
        lastBalanceFetch = Date()
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
            let due = self.lastQuickSwitchFetch.map { Date().timeIntervalSince($0) >= 60 } ?? true
            guard force || due else { return }
            self.lastQuickSwitchFetch = Date()
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
                    self.updateQuickSwitchSummary(
                        providerID: source.id,
                        text: Self.formatBalanceSummary(response.output.amount, unit: response.output.unit)
                    )
                }
            }
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
                self.updateQuickSwitchSummary(
                    providerID: providerID,
                    text: Self.formatBalanceSummary(response.output.amount, unit: response.output.unit)
                )
                self.renderForCurrentProvider(
                    .balance(providerName, response.output.amount, response.output.unit, query.websiteURL, Date()),
                    providerID: providerID,
                    client: client
                )
            case .failure(.nonHTTPS):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: tr("余额接口不是 HTTPS", "The balance endpoint is not HTTPS", "餘額介面不是 HTTPS", "残高エンドポイントが HTTPS ではありません"), client: client)
            case .failure(.transport(let error)):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: Self.localizedBalanceNetworkErrorReason(error, language: AppLanguage.resolved), client: client)
            case .failure(.httpStatus):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: tr("余额接口返回异常", "The balance endpoint returned an error", "餘額介面傳回異常", "残高エンドポイントでエラーが返されました"), client: client)
            case .failure(.unsupportedFormat):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: tr("未识别余额格式", "Unrecognized balance format", "無法辨識餘額格式", "残高形式を認識できません"), client: client)
            case .failure(.invalidJSON):
                self.renderBalanceError(providerID: providerID, providerName: providerName, reason: tr("余额响应无法解析", "The balance response could not be parsed", "無法解析餘額回應", "残高レスポンスを解析できません"), client: client)
            }
            }
        ) else {
            return
        }
    }

    private func fetchOfficialQuota(providerID: String, providerName: String, client: AssistantClient) {
        officialQuotaClient.fetchQuota(client: client, providerID: providerID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.updateQuickSwitchSummary(providerID: providerID, text: "\(Int(response.output.remaining))% / \(response.output.daysText)")
                self.renderForCurrentProvider(
                    .official(providerName, response.output.remaining, response.output.label, response.output.reset, Date()),
                    providerID: providerID,
                    client: client
                )
            case .failure(.missingCredentials):
                self.renderForCurrentProvider(.error(tr("\(client.displayName) 官方账号：未找到本机登录态", "Official \(client.displayName): Local sign-in credentials were not found", "\(client.displayName) 官方帳號：找不到本機登入狀態", "\(client.displayName) 公式アカウント：ローカルログイン情報が見つかりません")), providerID: providerID, client: client)
            case .failure(.transport(let error)):
                self.renderForCurrentProvider(.error(tr("\(client.displayName) 官方账号：\(error.localizedDescription)", "Official \(client.displayName): \(error.localizedDescription)", "\(client.displayName) 官方帳號：\(error.localizedDescription)", "\(client.displayName) 公式アカウント：\(error.localizedDescription)")), providerID: providerID, client: client)
            case .failure:
                self.renderForCurrentProvider(.error(tr("\(client.displayName) 官方账号：额度接口返回异常", "Official \(client.displayName): The quota endpoint returned an error", "\(client.displayName) 官方帳號：額度介面傳回異常", "\(client.displayName) 公式アカウント：クォータエンドポイントでエラーが返されました")), providerID: providerID, client: client)
            }
        }
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
            return tr("网络请求失败", "Network request failed", "網路請求失敗", "ネットワークリクエストに失敗しました", language: language)
        }
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            return tr("网络请求超时", "Network request timed out", "網路請求逾時", "ネットワークリクエストがタイムアウトしました", language: language)
        case .notConnectedToInternet:
            return tr("无网络连接", "No internet connection", "沒有網路連線", "ネットワークに接続されていません", language: language)
        case .networkConnectionLost:
            return tr("网络连接已中断", "Network connection was lost", "網路連線已中斷", "ネットワーク接続が切断されました", language: language)
        case .cannotFindHost:
            return tr("找不到主机", "Host could not be found", "找不到主機", "ホストが見つかりません", language: language)
        case .cannotConnectToHost:
            return tr("无法连接主机", "Could not connect to host", "無法連線主機", "ホストに接続できません", language: language)
        case .secureConnectionFailed:
            return tr("安全连接失败", "Secure connection failed", "安全連線失敗", "安全な接続に失敗しました", language: language)
        default:
            return tr("网络请求失败", "Network request failed", "網路請求失敗", "ネットワークリクエストに失敗しました", language: language)
        }
    }
}
