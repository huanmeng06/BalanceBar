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

struct QuickSwitchMenuEntry: Equatable {
    let id: String
    let name: String
    let isCurrent: Bool
}

enum QuickSwitchMenuModel {
    static func entries(from choices: [ProviderChoice]) -> [QuickSwitchMenuEntry] {
        choices.map { choice in
            QuickSwitchMenuEntry(
                id: choice.id,
                name: choice.name,
                isCurrent: choice.isCurrent
            )
        }
    }
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

enum BalanceRefreshReason: Equatable {
    case initial
    case scheduled
    case manual
    case activityUsage
    case providerChanged
    case clientChanged
    case configurationChanged

    var forcesStandardProviderBalance: Bool {
        self != .scheduled
    }

    var forcesOpenCodexCardSources: Bool {
        switch self {
        case .scheduled, .activityUsage:
            return false
        case .initial, .manual, .providerChanged, .clientChanged, .configurationChanged:
            return true
        }
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

    var diagnosticName: String {
        switch self {
        case .quota: return "quota"
        case .balance: return "balance"
        }
    }
}

enum OpenCodexCardSource: Equatable, Hashable {
    case official
    case balance(providerID: String)
    case unavailable(category: OpenCodexCardCategory, reason: String)

    var diagnosticName: String {
        switch self {
        case .official:
            return "official"
        case .balance(let providerID):
            return "balance:\(providerID)"
        case .unavailable(let category, _):
            return "unavailable:\(category.diagnosticName)"
        }
    }
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

    var diagnosticName: String {
        switch self {
        case .loading(let category):
            return "loading/\(category.diagnosticName)"
        case .official:
            return "official/quota"
        case .balance:
            return "balance"
        case .unavailable(let category, _):
            return "unavailable/\(category.diagnosticName)"
        }
    }

    var isSuccessful: Bool {
        switch self {
        case .official, .balance:
            return true
        case .loading, .unavailable:
            return false
        }
    }
}

struct OpenCodexCardRefreshSource: Equatable, Hashable {
    let source: OpenCodexCardSource
    let interval: TimeInterval
    let configurationFingerprint: String
}

struct OpenCodexCardRefreshPlan: Equatable {
    let dueSources: [OpenCodexCardRefreshSource]
    let configurationChanged: Set<OpenCodexCardSource>
}

struct OpenCodexCardRefreshCoordinator {
    private struct Entry {
        var visibleData: OpenCodexCardData?
        var lastSuccessfulData: OpenCodexCardData?
        var lastRequestedAt: Date?
        var configurationFingerprint: String
        var generation: UUID
    }

    private var entries: [OpenCodexCardSource: Entry] = [:]

    mutating func reset() {
        entries.removeAll()
    }

    mutating func plan(
        sources: [OpenCodexCardRefreshSource],
        now: Date,
        force: Bool,
        allowRequests: Bool,
        inFlight: Set<OpenCodexCardSource>
    ) -> OpenCodexCardRefreshPlan {
        let activeSources = Set(sources.map(\OpenCodexCardRefreshSource.source))
        entries = entries.filter { activeSources.contains($0.key) }

        var dueSources: [OpenCodexCardRefreshSource] = []
        var configurationChanged = Set<OpenCodexCardSource>()
        var seenSources = Set<OpenCodexCardSource>()

        for descriptor in sources {
            guard seenSources.insert(descriptor.source).inserted else { continue }

            let previous = entries[descriptor.source]
            let changed = previous?.configurationFingerprint != descriptor.configurationFingerprint
            if changed {
                entries[descriptor.source] = Entry(
                    visibleData: nil,
                    lastSuccessfulData: nil,
                    lastRequestedAt: nil,
                    configurationFingerprint: descriptor.configurationFingerprint,
                    generation: UUID()
                )
                configurationChanged.insert(descriptor.source)
            } else if previous == nil {
                entries[descriptor.source] = Entry(
                    visibleData: nil,
                    lastSuccessfulData: nil,
                    lastRequestedAt: nil,
                    configurationFingerprint: descriptor.configurationFingerprint,
                    generation: UUID()
                )
            }

            guard allowRequests,
                  let entry = entries[descriptor.source] else { continue }
            let interval = max(TimeInterval(60), descriptor.interval)
            let due = force
                || changed
                || entry.lastRequestedAt.map {
                    now.timeIntervalSince($0) >= interval
                } ?? true
            guard due,
                  changed || !inFlight.contains(descriptor.source) else { continue }

            entries[descriptor.source]?.lastRequestedAt = now
            dueSources.append(descriptor)
        }

        return OpenCodexCardRefreshPlan(
            dueSources: dueSources,
            configurationChanged: configurationChanged
        )
    }

    func visibleData(for source: OpenCodexCardSource) -> OpenCodexCardData? {
        entries[source]?.visibleData
    }

    func lastSuccessfulData(for source: OpenCodexCardSource) -> OpenCodexCardData? {
        entries[source]?.lastSuccessfulData
    }

    func lastRequestedAt(for source: OpenCodexCardSource) -> Date? {
        entries[source]?.lastRequestedAt
    }

    func generation(for source: OpenCodexCardSource) -> UUID? {
        entries[source]?.generation
    }

    @discardableResult
    mutating func store(
        _ data: OpenCodexCardData,
        for source: OpenCodexCardSource,
        generation: UUID
    ) -> OpenCodexCardData? {
        guard var entry = entries[source], entry.generation == generation else {
            return nil
        }

        if data.isSuccessful {
            entry.visibleData = data
            entry.lastSuccessfulData = data
        } else if let lastSuccessfulData = entry.lastSuccessfulData {
            // A failed refresh must not replace a previously verified card
            // with a transient unavailable state. Keep the timestamped
            // successful data visible until the next successful refresh.
            entry.visibleData = lastSuccessfulData
        } else {
            entry.visibleData = data
        }
        entries[source] = entry
        return entry.visibleData
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

enum OpenCodexCardPresentation {
    enum CurrentCardMatch: Equatable {
        case isCurrent(OpenCodexModelCard)
        case exactSelector(OpenCodexModelCard)
        case canonicalSelector(OpenCodexModelCard)
        case none

        var card: OpenCodexModelCard? {
            switch self {
            case .isCurrent(let card), .exactSelector(let card), .canonicalSelector(let card):
                return card
            case .none:
                return nil
            }
        }

        var diagnosticReason: String {
            switch self {
            case .isCurrent: return "isCurrent"
            case .exactSelector: return "exact-selector"
            case .canonicalSelector: return "canonical-selector"
            case .none: return "no-match"
            }
        }
    }

    static func identity(for card: OpenCodexModelCard) -> String {
        "\(card.provider)/\(card.model)"
    }

    static func currentCard(
        from cards: [OpenCodexModelCard],
        fallbackSelector: String? = nil
    ) -> OpenCodexModelCard? {
        currentCardMatch(
            from: cards,
            fallbackSelector: fallbackSelector
        ).card
    }

    static func currentCardMatch(
        from cards: [OpenCodexModelCard],
        fallbackSelector: String?
    ) -> CurrentCardMatch {
        if let current = cards.first(where: \OpenCodexModelCard.isCurrent) {
            return .isCurrent(current)
        }

        guard let fallbackSelector = normalizedSelector(fallbackSelector) else {
            return .none
        }
        if let exact = cards.first(where: {
            normalizedSelector($0.selector) == fallbackSelector
        }) {
            return .exactSelector(exact)
        }
        guard let canonicalFallback = canonicalSelector(fallbackSelector) else {
            return .none
        }
        guard let canonical = cards.first(where: {
            canonicalSelector($0.selector) == canonicalFallback
        }) else {
            return .none
        }
        return .canonicalSelector(canonical)
    }

    /// The menu bar summarizes the selected card, while the status-menu card
    /// itself may continue to show the selector/model identity. Keeping this
    /// mapping pure prevents transient card states from leaking that identity
    /// into the compact menu-bar presentation.
    static func menuBarSnapshot(
        for card: OpenCodexModelCard?
    ) -> Snapshot {
        guard let card else { return .placeholder }

        switch card.data {
        case .official(let remaining, let label, let reset, let updatedAt):
            return .official(
                card.provider,
                remaining,
                label,
                reset,
                updatedAt
            )
        case .balance(let amount, let unit, let websiteURL, let updatedAt):
            return .balance(
                card.provider,
                amount,
                unit,
                websiteURL,
                updatedAt
            )
        case .loading:
            return .placeholder
        case .unavailable(_, let reason):
            return .error(reason)
        }
    }

    /// Resolve the compact presentation from the latest published card list.
    /// Keeping the base OpenCodex snapshot separate is important because it
    /// carries selector/status text for the full status menu, while the menu
    /// bar must be recomputed whenever card data is published.
    static func menuBarSnapshot(
        for snapshot: Snapshot,
        cards: [OpenCodexModelCard]
    ) -> Snapshot {
        guard snapshot.kind == .openCodex else { return snapshot }
        switch currentCardMatch(from: cards, fallbackSelector: snapshot.unit) {
        case .isCurrent(let card), .exactSelector(let card), .canonicalSelector(let card):
            return menuBarSnapshot(for: card)
        case .none:
            return cards.isEmpty
                ? .placeholder
                : .error(
                    tr(
                        "OpenCodex 当前精选模型未匹配",
                        "The current OpenCodex model could not be matched"
                    )
                )
        }
    }

    private static func normalizedSelector(_ selector: String?) -> String? {
        guard let selector else { return nil }
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func canonicalSelector(_ selector: String) -> String? {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let provider: String
        let model: String
        if let slash = trimmed.firstIndex(of: "/") {
            provider = String(trimmed[..<slash])
            model = String(trimmed[trimmed.index(after: slash)...])
        } else {
            provider = "openai"
            model = trimmed
        }
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProvider.isEmpty, !normalizedModel.isEmpty else { return nil }
        return normalizedProvider == "openai"
            ? normalizedModel
            : "\(normalizedProvider)/\(normalizedModel)"
    }

    static func dashboardURL(
        confirmedProviderID: String?,
        currentProviderID: String?,
        candidate: OpenCodexEndpointCandidate?
    ) -> URL? {
        guard let confirmedProviderID,
              confirmedProviderID == currentProviderID else { return nil }
        return candidate?.dashboardURL
    }
}

/// Frames shared by OpenCodex cards and the existing overview cards.
/// Keeping these values in a pure helper makes the visual baseline testable
/// without launching AppKit or the status menu.
struct OpenCodexCardFrames: Equatable {
    let cardSize: CGSize
    let title: CGRect
    let refreshTime: CGRect
    let quotaDetail: CGRect
    let reset: CGRect?
    let amount: CGRect
    let progress: CGRect?
    let linkPrefix: CGRect?
    let link: CGRect?
}

enum OpenCodexCardLayout {
    static let cardWidth: CGFloat = 304
    static let horizontalInset: CGFloat = 14
    static let contentWidth = cardWidth - horizontalInset * 2
    static let amountWidth: CGFloat = 141
    static let amountX = cardWidth - horizontalInset - amountWidth
    static let refreshTimeX = cardWidth - horizontalInset - 81

    static func frames(
        for category: OpenCodexCardCategory,
        linkPrefixWidth: CGFloat = 62
    ) -> OpenCodexCardFrames {
        switch category {
        case .quota:
            return OpenCodexCardFrames(
                cardSize: CGSize(width: cardWidth, height: 102),
                title: CGRect(x: horizontalInset, y: 75, width: 189, height: 20),
                refreshTime: CGRect(x: refreshTimeX, y: 76, width: 81, height: 17),
                quotaDetail: CGRect(x: horizontalInset, y: 47, width: 128, height: 18),
                reset: CGRect(x: horizontalInset, y: 28, width: 128, height: 17),
                amount: CGRect(x: amountX, y: 18, width: amountWidth, height: 48),
                progress: CGRect(x: horizontalInset, y: 8, width: contentWidth, height: 5),
                linkPrefix: nil,
                link: nil
            )
        case .balance:
            let linkWidth: CGFloat = linkPrefixWidth == 62 ? 148 : 136
            let linkX: CGFloat = horizontalInset + linkPrefixWidth - 1
            return OpenCodexCardFrames(
                cardSize: CGSize(width: cardWidth, height: 86),
                title: CGRect(x: horizontalInset, y: 58, width: 189, height: 20),
                refreshTime: CGRect(x: refreshTimeX, y: 59, width: 81, height: 17),
                quotaDetail: CGRect(x: horizontalInset, y: 31, width: 128, height: 18),
                reset: nil,
                amount: CGRect(x: amountX, y: 5, width: amountWidth, height: 48),
                progress: nil,
                linkPrefix: CGRect(x: horizontalInset, y: 7, width: linkPrefixWidth, height: 17),
                link: CGRect(x: linkX, y: 7, width: linkWidth, height: 17)
            )
        }
    }
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
                && secureWebsiteURL(for: source) != nil
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
        guard isSecureHTTPSURL(descriptorURL),
              let descriptorHost = normalizedHost(descriptorURL) else { return false }
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
              isSecureHTTPSURL(url) else { return nil }
        return url
    }

    private static func secureWebsiteURL(for source: ProviderSummarySource) -> URL? {
        let url = source.websiteURL ?? source.query?.websiteURL
        guard let url,
              isSecureHTTPSURL(url),
              let host = normalizedHost(url),
              !isLoopbackHost(host) else { return nil }
        return url
    }

    private static func isSecureHTTPSURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = normalizedHost(url),
              !isLoopbackHost(host),
              url.user == nil,
              url.password == nil else { return false }
        return true
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
            || host == "::"
            || host == "0.0.0.0"
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
