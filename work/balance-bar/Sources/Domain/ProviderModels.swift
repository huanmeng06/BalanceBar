import Foundation

struct ProviderBalanceSnapshotCache {
    private struct Key: Hashable {
        let clientID: String
        let providerID: String
    }

    private var snapshots: [Key: Snapshot] = [:]

    mutating func store(_ snapshot: Snapshot, clientID: String, providerID: String) {
        guard snapshot.kind == .balance else { return }
        snapshots[Key(clientID: clientID, providerID: providerID)] = snapshot
    }

    func errorSnapshot(
        clientID: String,
        providerID: String,
        providerName: String,
        reason: String
    ) -> Snapshot {
        Snapshot.providerError(
            providerName,
            reason: reason,
            cachedBalance: snapshots[Key(clientID: clientID, providerID: providerID)]
        )
    }
}

struct ProviderChoice {
    let id: String
    let name: String
    let isCurrent: Bool
}

struct ProviderSummarySource {
    let id: String
    let name: String
    let isOfficial: Bool
    let query: BalanceQuery?
    let officialAccessToken: String?
    let openCodexCandidate: OpenCodexEndpointCandidate?
    let websiteURL: URL?

    init(
        id: String,
        name: String = "",
        isOfficial: Bool,
        query: BalanceQuery?,
        officialAccessToken: String?,
        openCodexCandidate: OpenCodexEndpointCandidate?,
        websiteURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.isOfficial = isOfficial
        self.query = query
        self.officialAccessToken = officialAccessToken
        self.openCodexCandidate = openCodexCandidate
        self.websiteURL = websiteURL
    }
}

enum OpenCodexCardCategory: Equatable, Hashable {
    case quota
    case balance

    var unavailableTitle: String {
        switch self {
        case .quota:
            return tr("额度不可用", "Quota unavailable")
        case .balance:
            return tr("余额不可用", "Balance unavailable")
        }
    }
}

enum OpenCodexCardSource: Equatable, Hashable {
    case official
    case balance(providerID: String)
    case unavailable(category: OpenCodexCardCategory, reason: String)
}

enum OpenCodexCardData: Equatable {
    case loading(category: OpenCodexCardCategory)
    case official(
        remaining: Double,
        label: String,
        reset: String?,
        updatedAt: Date
    )
    case balance(
        amount: Double,
        unit: String,
        websiteURL: URL?,
        updatedAt: Date
    )
    case unavailable(category: OpenCodexCardCategory, reason: String)

    var category: OpenCodexCardCategory {
        switch self {
        case .loading(let category), .unavailable(let category, _):
            return category
        case .official:
            return .quota
        case .balance:
            return .balance
        }
    }
}

struct OpenCodexCardPlan: Equatable {
    let selector: String
    let provider: String
    let model: String
    let isCurrent: Bool
    let source: OpenCodexCardSource
}

struct OpenCodexModelCard: Equatable {
    let selector: String
    let provider: String
    let model: String
    let isCurrent: Bool
    let data: OpenCodexCardData
}

enum OpenCodexCardPlanner {
    static let maxCards = 5

    static func plans(
        state: OpenCodexRuntimeState,
        sources: [ProviderSummarySource]
    ) -> [OpenCodexCardPlan] {
        state.preferences.prefix(maxCards).map { preference in
            let source = source(
                for: preference.provider,
                state: state,
                sources: sources
            )
            return OpenCodexCardPlan(
                selector: preference.selector,
                provider: preference.provider,
                model: preference.model,
                isCurrent: preference.isCurrent,
                source: source
            )
        }
    }

    static func cards(
        plans: [OpenCodexCardPlan],
        data: [OpenCodexCardSource: OpenCodexCardData]
    ) -> [OpenCodexModelCard] {
        plans.prefix(maxCards).map { plan in
            let resolved: OpenCodexCardData
            switch plan.source {
            case .unavailable(let category, let reason):
                resolved = .unavailable(category: category, reason: reason)
            default:
                resolved = data[plan.source] ?? .loading(category: plan.source.category)
            }
            return OpenCodexModelCard(
                selector: plan.selector,
                provider: plan.provider,
                model: plan.model,
                isCurrent: plan.isCurrent,
                data: resolved
            )
        }
    }

    private static func source(
        for providerID: String,
        state: OpenCodexRuntimeState,
        sources: [ProviderSummarySource]
    ) -> OpenCodexCardSource {
        guard let descriptor = state.providers[providerID] else {
            return .unavailable(
                category: .balance,
                reason: tr(
                    "未读取到上游 provider 身份",
                    "The upstream provider identity was not read"
                )
            )
        }
        if descriptor.isOfficial {
            return .official
        }

        let candidates = sources.filter { source in
            !source.isOfficial
                && source.openCodexCandidate == nil
                && source.query != nil
                && secureRequestURL(for: source.query) != nil
                && hostsMatch(descriptor.baseURL, source: source)
        }
        let exactNameMatches = candidates.filter {
            normalized($0.name) == normalized(descriptor.id)
        }
        let selected: ProviderSummarySource?
        if exactNameMatches.count == 1 {
            selected = exactNameMatches[0]
        } else if exactNameMatches.isEmpty, candidates.count == 1 {
            selected = candidates[0]
        } else {
            selected = nil
        }
        guard let selected else {
            return .unavailable(
                category: .balance,
                reason: tr(
                    "未找到可验证的余额来源",
                    "No verifiable balance source was found"
                )
            )
        }
        return .balance(providerID: selected.id)
    }

    private static func hostsMatch(
        _ descriptorURL: URL,
        source: ProviderSummarySource
    ) -> Bool {
        guard let descriptorHost = normalizedHost(descriptorURL) else { return false }
        let queryHost = source.query.flatMap { URL(string: $0.url) }.flatMap(normalizedHost)
        let websiteHost = normalizedHost(source.websiteURL ?? source.query?.websiteURL)
        guard !isLoopbackHost(descriptorHost),
              queryHost.map({ !isLoopbackHost($0) }) ?? true,
              websiteHost.map({ !isLoopbackHost($0) }) ?? true else {
            return false
        }
        return descriptorHost == queryHost || descriptorHost == websiteHost
    }

    private static func secureRequestURL(for query: BalanceQuery?) -> URL? {
        guard let query,
              let url = URL(string: query.url),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    private static func normalizedHost(_ url: URL?) -> String? {
        guard let url,
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else { return nil }
        return host
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost"
            || host == "::1"
            || host == "127.0.0.1"
            || (host.hasPrefix("127.") && host.split(separator: ".").count == 4)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension OpenCodexCardSource {
    var category: OpenCodexCardCategory {
        switch self {
        case .official:
            return .quota
        case .balance:
            return .balance
        case .unavailable(let category, _):
            return category
        }
    }
}
