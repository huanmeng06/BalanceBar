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

enum OpenAISubscriptionTier: Equatable {
    case plus
    case proFiveX
    case proTwentyX

    init?(planType: String?) {
        guard let planType else { return nil }
        switch planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plus":
            self = .plus
        case "prolite", "pro_5x", "pro5x":
            self = .proFiveX
        case "pro", "pro_20x", "pro20x":
            self = .proTwentyX
        default:
            return nil
        }
    }

    var text: String {
        switch self {
        case .plus:
            return "PLUS"
        case .proFiveX:
            return "Pro · 5x"
        case .proTwentyX:
            return "Pro · 20x"
        }
    }
}

struct OpenAIAccountPresentation: Equatable {
    enum State: Equatable {
        case available(String)
        case unavailable
    }

    let state: State
    let subscription: OpenAISubscriptionTier?

    init(email: String?, subscription: OpenAISubscriptionTier? = nil) {
        if let email {
            let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines)
            state = normalized.isEmpty ? .unavailable : .available(normalized)
            self.subscription = normalized.isEmpty ? nil : subscription
        } else {
            state = .unavailable
            self.subscription = nil
        }
    }

    static func current(
        activeClient: AssistantClient,
        providerIsOfficial: Bool,
        email: String?,
        subscription: OpenAISubscriptionTier? = nil
    ) -> Self? {
        guard activeClient == .codex, providerIsOfficial else { return nil }
        return Self(email: email, subscription: subscription)
    }

    func text(language: AppLanguage = .selected) -> String {
        switch state {
        case .available(let email):
            return tr(
                email,
                email,
                email,
                email,
                language: language
            )
        case .unavailable:
            return tr(
                "账号不可用",
                "Account unavailable",
                "帳號不可用",
                "アカウントを利用できません",
                language: language
            )
        }
    }
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
            return tr("额度不可用", "Quota unavailable", "額度不可用", "クォータを利用できません")
        case .balance:
            return tr("余额不可用", "Balance unavailable", "餘額不可用", "残高を利用できません")
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
    enum MenuBarCardMatch: Equatable {
        case firstPreference(OpenCodexModelCard)
        case none

        var card: OpenCodexModelCard? {
            switch self {
            case .firstPreference(let card): return card
            case .none: return nil
            }
        }

        var diagnosticReason: String {
            switch self {
            case .firstPreference: return "first-preference"
            case .none: return "no-preference"
            }
        }
    }

    static func identity(for card: OpenCodexModelCard) -> String {
        "\(card.provider)/\(card.model)"
    }

    /// The menu bar follows the OpenCodex preference order exactly. The
    /// `isCurrent` marker and runtime selector describe another UI concern and
    /// must not make a later card replace the first preference here.
    static func menuBarCardMatch(
        from cards: [OpenCodexModelCard]
    ) -> MenuBarCardMatch {
        guard let first = cards.first else { return .none }
        return .firstPreference(first)
    }

    /// The menu bar summarizes the first preference card, while the status-menu
    /// card itself may continue to show the selector/model identity. Keeping
    /// this mapping pure prevents card identity from leaking into the compact
    /// menu-bar presentation.
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
        switch menuBarCardMatch(from: cards) {
        case .firstPreference(let card):
            return menuBarSnapshot(for: card)
        case .none:
            return .placeholder
        }
    }

    static func dashboardURL(
        confirmedProviderID: String?,
        currentProviderID: String?,
        candidate: OpenCodexEndpointCandidate?,
        manualPort: Int? = nil
    ) -> URL? {
        guard let confirmedProviderID,
              confirmedProviderID == currentProviderID,
              candidate != nil || manualPort != nil else { return nil }
        return OpenCodexDashboardResolver.resolve(
            manualPort: manualPort,
            runtimeCandidate: candidate
        ).url
    }
}

/// Frames shared by OpenCodex cards and the existing overview cards.
/// Keeping these values in a pure helper makes the visual baseline testable
/// without launching AppKit or the status menu.
struct OpenCodexCardFrames: Equatable {
    let cardSize: CGSize
    let title: CGRect
    let refreshTime: CGRect
    let account: CGRect?
    let subscription: CGRect?
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
    static let subscriptionBadgeWidth: CGFloat = 78
    static let subscriptionGap: CGFloat = 8
    static let amountWidth: CGFloat = 141
    static let amountX = cardWidth - horizontalInset - amountWidth
    static let refreshTimeX = cardWidth - horizontalInset - 81

    static func frames(
        for category: OpenCodexCardCategory,
        linkPrefixWidth: CGFloat = 62,
        includesAccount: Bool = false,
        includesSubscription: Bool = false
    ) -> OpenCodexCardFrames {
        switch category {
        case .quota:
            let hasSubscription = includesAccount && includesSubscription
            let accountShift: CGFloat = includesAccount ? (hasSubscription ? 20 : 19) : 0
            let accountWidth = hasSubscription
                ? contentWidth - subscriptionBadgeWidth - subscriptionGap
                : contentWidth
            return OpenCodexCardFrames(
                cardSize: CGSize(width: cardWidth, height: 102 + accountShift),
                title: CGRect(x: horizontalInset, y: 75 + accountShift, width: 189, height: 20),
                refreshTime: CGRect(x: refreshTimeX, y: 76 + accountShift, width: 81, height: 17),
                account: includesAccount
                    ? CGRect(x: horizontalInset, y: 75, width: accountWidth, height: 17)
                    : nil,
                subscription: hasSubscription
                    ? CGRect(
                        x: cardWidth - horizontalInset - subscriptionBadgeWidth,
                        y: 72,
                        width: subscriptionBadgeWidth,
                        height: 22
                    )
                    : nil,
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
                account: nil,
                subscription: nil,
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
            logSourceMatch(
                providerID: providerID,
                host: nil,
                candidates: [],
                strategy: "missing-provider",
                selected: nil
            )
            return .unavailable(
                category: .balance,
                reason: tr(
                    "未读取到上游 provider 身份",
                    "The upstream provider identity was not read",
                    "未讀取到上游 provider 身分",
                    "上流プロバイダーの識別情報が読み取られていません"
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
        let exactRawNameMatches = candidates.filter {
            $0.name == descriptor.id
        }
        let normalizedNameMatches = candidates.filter {
            normalized($0.name) == normalized(descriptor.id)
        }
        let credentialMatches: [ProviderSummarySource]
        if descriptor.apiKeys.isEmpty {
            credentialMatches = []
        } else {
            let credentials = Set(descriptor.apiKeys)
            credentialMatches = candidates.filter { source in
                guard let apiKey = source.query?.apiKey
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !apiKey.isEmpty else { return false }
                return credentials.contains(apiKey)
            }
        }

        let selected: ProviderSummarySource?
        let strategy: String
        if credentialMatches.count == 1 {
            selected = credentialMatches[0]
            strategy = "unique-credential"
        } else if credentialMatches.count > 1 {
            selected = nil
            strategy = "ambiguous-credential"
        } else if exactRawNameMatches.count == 1,
                  normalizedNameMatches.count == 1 {
            // A case-only name difference is not an identity signal. The
            // normalized count guard keeps a pair such as `tokenshop` and
            // `Tokenshop` ambiguous unless credentials disambiguate it.
            selected = exactRawNameMatches[0]
            strategy = "unique-exact-name"
        } else if candidates.count == 1 {
            selected = candidates[0]
            strategy = "unique-candidate"
        } else if candidates.isEmpty {
            selected = nil
            strategy = "no-safe-host-candidate"
        } else {
            selected = nil
            strategy = "ambiguous-name-or-candidate"
        }
        logSourceMatch(
            providerID: descriptor.id,
            host: normalizedHost(descriptor.baseURL),
            candidates: candidates,
            strategy: strategy,
            selected: selected,
            credentialMatchCount: credentialMatches.count,
            exactNameMatchCount: exactRawNameMatches.count,
            normalizedNameMatchCount: normalizedNameMatches.count
        )
        guard let selected else {
            let reason = candidates.count > 1 || credentialMatches.count > 1
                ? tr(
                    "找到多个余额来源，无法确认账户",
                    "Multiple balance sources were found; the account could not be confirmed",
                    "找到多個餘額來源，無法確認帳戶",
                    "複数の残高ソースが見つかり、アカウントを確認できませんでした"
                )
                : tr(
                    "未找到可验证的余额来源",
                    "No verifiable balance source was found",
                    "找不到可驗證的餘額來源",
                    "検証可能な残高ソースが見つかりませんでした"
                )
            return .unavailable(
                category: .balance,
                reason: reason
            )
        }
        return .balance(providerID: selected.id)
    }

    private static func logSourceMatch(
        providerID: String,
        host: String?,
        candidates: [ProviderSummarySource],
        strategy: String,
        selected: ProviderSummarySource?,
        credentialMatchCount: Int = 0,
        exactNameMatchCount: Int = 0,
        normalizedNameMatchCount: Int = 0
    ) {
        let candidateSummary = candidates.map { source in
            "id=\(source.id),name=\(source.name),host=\(diagnosticHost(for: source))"
        }.joined(separator: "|")
        SwitchLog.write(
            "OpenCodex balance source match; provider_id=\(providerID); host=\(host ?? "unknown"); candidate_count=\(candidates.count); credential_match_count=\(credentialMatchCount); exact_name_match_count=\(exactNameMatchCount); normalized_name_match_count=\(normalizedNameMatchCount); candidates=\(candidateSummary.isEmpty ? "<none>" : candidateSummary); strategy=\(strategy); selected_source_id=\(selected?.id ?? "none")",
            level: strategy.hasPrefix("ambiguous") ? .warning : .debug,
            category: "open-codex.source-match",
            throttleKey: "open-codex-source-match-\(providerID)",
            minimumInterval: 1
        )
    }

    private static func diagnosticHost(for source: ProviderSummarySource) -> String {
        normalizedHost(URL(string: source.query?.url ?? ""))
            ?? normalizedHost(source.websiteURL ?? source.query?.websiteURL)
            ?? "unknown"
    }

    private static func hostsMatch(
        _ descriptorURL: URL,
        source: ProviderSummarySource
    ) -> Bool {
        guard isSecureHTTPSURL(descriptorURL),
              let descriptorHost = normalizedHost(descriptorURL) else { return false }
        let queryHost = source.query.flatMap { URL(string: $0.url) }.flatMap(normalizedHost)
        let websiteHost = normalizedHost(source.websiteURL ?? source.query?.websiteURL)
        guard !OpenCodexHostSecurity.isLocalOnlyHost(descriptorHost),
              queryHost.map({ !OpenCodexHostSecurity.isLocalOnlyHost($0) }) ?? true,
              websiteHost.map({ !OpenCodexHostSecurity.isLocalOnlyHost($0) }) ?? true else {
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
              !OpenCodexHostSecurity.isLocalOnlyHost(host) else { return nil }
        return url
    }

    private static func isSecureHTTPSURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = normalizedHost(url),
              !OpenCodexHostSecurity.isLocalOnlyHost(host),
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
