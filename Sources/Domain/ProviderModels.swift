import AppKit
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
            return tr(.keyProviderModelsValue, arguments: [String(describing: email)], language: language)
        case .unavailable:
            return tr(.keyProviderModelsAccountUnavailable, language: language)
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
    let websiteURL: URL?
    let configurationRevision: String
    let officialAccount: CodexAccountProfile?
    let notes: String?

    init(
        id: String,
        name: String = "",
        isOfficial: Bool,
        query: BalanceQuery?,
        officialAccessToken: String?,
        websiteURL: URL? = nil,
        configurationRevision: String = "",
        officialAccount: CodexAccountProfile? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isOfficial = isOfficial
        self.query = query
        self.officialAccessToken = officialAccessToken
        self.websiteURL = websiteURL
        self.configurationRevision = configurationRevision
        self.officialAccount = officialAccount
        self.notes = notes
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
    case databaseChanged

    var forcesStandardProviderBalance: Bool {
        self != .scheduled && self != .databaseChanged
    }
}

enum OpenCodexCardCategory: Equatable, Hashable {
    case quota
    case balance

    var unavailableTitle: String {
        switch self {
        case .quota:
            return tr(.keyProviderModelsQuotaUnavailable)
        case .balance:
            return tr(.keyProviderModelsBalanceUnavailable)
        }
    }

    var diagnosticName: String {
        switch self {
        case .quota: return "quota"
        case .balance: return "balance"
        }
    }
}

/// Shared spacing contract for the overview card. Values describe one
/// layout layer only: section spacing never changes text or ticket spacing.
struct OverviewLayoutMetrics: Equatable {
    let horizontalInset: CGFloat
    let sectionSpacing: CGFloat
    let subsectionSpacing: CGFloat
    let quotaRowSpacing: CGFloat
    let titleSubtitleSpacing: CGFloat
    let subtitleProgressSpacing: CGFloat
    let ticketSpacing: CGFloat

    static let `default` = Self(
        horizontalInset: 16,
        sectionSpacing: 22,
        subsectionSpacing: 16,
        quotaRowSpacing: 12,
        titleSubtitleSpacing: 2,
        subtitleProgressSpacing: 7,
        ticketSpacing: 8
    )
}

enum OpenCodexOverviewSectionID: Hashable {
    case account
    case fiveHour
    case sevenDay
    case otherQuota(String)
    case legacyQuota
    case lunaReserve
    case resetProbability
    case bankedReset

    static func quota(_ window: OfficialQuotaWindow, index: Int) -> Self {
        switch window.kind {
        case .fiveHour: return .fiveHour
        case .sevenDay: return .sevenDay
        case .other: return .otherQuota(window.label)
        }
    }

    var identifier: String {
        switch self {
        case .account: return "account"
        case .fiveHour: return "fiveHour"
        case .sevenDay: return "sevenDay"
        case .otherQuota(let label): return "otherQuota.\(label)"
        case .legacyQuota: return "legacyQuota"
        case .lunaReserve: return "lunaReserve"
        case .resetProbability: return "resetProbability"
        case .bankedReset: return "bankedReset"
        }
    }
}

struct OpenCodexAccountSectionFrames: Equatable {
    let title: CGRect
    let refreshTime: CGRect
    let account: CGRect?
    let subscription: CGRect?

    func offsetBy(dy: CGFloat) -> Self {
        Self(title: title.offsetBy(dx: 0, dy: dy), refreshTime: refreshTime.offsetBy(dx: 0, dy: dy),
             account: account?.offsetBy(dx: 0, dy: dy), subscription: subscription?.offsetBy(dx: 0, dy: dy))
    }
}

/// Placement belongs to the card; all content belongs to the section's local
/// coordinate system. Ticket frames are separately document-local.
struct OpenCodexOverviewSectionLayout: Equatable {
    let id: OpenCodexOverviewSectionID
    let frame: CGRect
    let row: OpenCodexQuotaRowFrames?
    var header: OpenCodexAccountSectionFrames? = nil
    var isVisible: Bool { true }
    var height: CGFloat { frame.height }
    var cardRow: OpenCodexQuotaRowFrames? { row?.offsetBy(dx: frame.minX, dy: frame.minY) }
}

enum OpenCodexTicketLayoutMode: Equatable {
    case compact
    case expanded
}

struct OpenCodexTicketTextMetrics: Equatable {
    let titleWidth: CGFloat
    let windowWidth: CGFloat
    let resetWidth: CGFloat
    let amountWidth: CGFloat

    static let empty = Self(titleWidth: 0, windowWidth: 0, resetWidth: 0, amountWidth: 0)
}

/// Frames used by official quota and balance overview cards.
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
    let quotaRows: [OpenCodexQuotaRowFrames]
    let lunaReserveRow: OpenCodexQuotaRowFrames?
    let bankedResetSummaryRow: OpenCodexQuotaRowFrames?
    /// Independent quota-style row for reset probability. Nil when the
    /// banked-reset section is hidden. Its amount is the large primary
    /// figure; `reset` is the data-source subtitle under the title.
    let bankedResetProbabilityRow: OpenCodexQuotaRowFrames?
    /// Subtitle slot shared by the unified 48h forecast, official hint,
    /// and countdown progress presentations.
    let bankedResetForecastMetrics: CGRect?
    let bankedResetForecastConfidence: CGRect?
    /// Document-local frames for every ticket, including unscrolled 1–2 lists.
    /// Never union these with card-coordinate section placements.
    let bankedResetDetailRows: [OpenCodexQuotaRowFrames]
    /// Host-coordinate clip for the detailed ticket list. Nil when the
    /// overview has no tickets. 1–2 tickets fill this rect; 3+ clip to
    /// `bankedResetTicketViewportMaxHeight` and scroll inside it.
    let bankedResetTicketViewport: CGRect?

    var balanceRecharge: CGRect? = nil

    /// Produced by the section compositor, never inferred from child frames.
    var sectionLayouts: [OpenCodexOverviewSectionLayout] = []
}

struct OpenCodexQuotaRowFrames: Equatable {
    let quotaDetail: CGRect
    let reset: CGRect
    let amount: CGRect
    let progress: CGRect
    let icon: CGRect
    let window: CGRect
    let badge: CGRect
    let chrome: CGRect

    init(
        quotaDetail: CGRect,
        reset: CGRect,
        amount: CGRect,
        progress: CGRect,
        icon: CGRect = .zero,
        window: CGRect = .zero,
        badge: CGRect = .zero,
        chrome: CGRect = .zero
    ) {
        self.quotaDetail = quotaDetail
        self.reset = reset
        self.amount = amount
        self.progress = progress
        self.icon = icon
        self.window = window
        self.badge = badge
        self.chrome = chrome
    }
}

extension OpenCodexQuotaRowFrames {
    func withResetVisible(_ visible: Bool) -> Self {
        Self(quotaDetail: quotaDetail, reset: visible ? reset : .zero,
             amount: amount, progress: progress, icon: icon, window: window, badge: badge, chrome: chrome)
    }

    func offsetBy(dx: CGFloat = 0, dy: CGFloat) -> Self {
        func translated(_ rect: CGRect) -> CGRect {
            rect.isEmpty ? .zero : rect.offsetBy(dx: dx, dy: dy)
        }
        return Self(quotaDetail: translated(quotaDetail), reset: translated(reset),
                    amount: translated(amount), progress: translated(progress),
                    icon: translated(icon), window: translated(window),
                    badge: translated(badge), chrome: translated(chrome))
    }
}

enum OpenCodexCardLayout {
    static let cardWidth: CGFloat = 304
    static let showsSectionOutlines = false
    static let metrics = OverviewLayoutMetrics.default
    static let horizontalInset: CGFloat = metrics.horizontalInset
    static let contentWidth = cardWidth - horizontalInset * 2
    static let subscriptionWidth: CGFloat = 78
    static let subscriptionX = cardWidth - horizontalInset - subscriptionWidth
    // Keep the marquee's transparent edge a few points before the actual
    // right-aligned subscription glyphs. This is a layout gap, not a text or
    // language-specific adjustment.
    static let subscriptionTextSafetyGap: CGFloat = 8
    // Geometry-only fallback used when the right-aligned subscription text has
    // not been measured yet. Runtime callers refine this to the text edge.
    static let accountWidthWithSubscription = subscriptionX - horizontalInset
    static let amountWidth: CGFloat = 141
    static let amountX = cardWidth - horizontalInset - amountWidth
    static let refreshTimeX = cardWidth - horizontalInset - 81

    // Keep the official quota rows on the same AppKit text and progress
    // metrics as the existing single-window quota card. The expanded card
    // gets its extra height from these row metrics and the inter-row gap,
    // rather than shrinking the rendered content.
    static let quotaAmountPointSize: CGFloat = 31
    static let quotaDetailPointSize: CGFloat = 13
    static let quotaResetPointSize: CGFloat = 13
    static let quotaRowHeight: CGFloat = 60
    static let quotaRowGap: CGFloat = metrics.quotaRowSpacing
    static let quotaBottomInset: CGFloat = 8
    static let quotaTitleGap: CGFloat = 11
    static let quotaAmountOffset: CGFloat = 10
    static let quotaResetOffset: CGFloat = 20
    static let quotaDetailOffset: CGFloat = quotaResetOffset + quotaResetHeight + metrics.titleSubtitleSpacing
    static let quotaAmountHeight: CGFloat = 48
    static let quotaResetHeight: CGFloat = 17
    static let quotaDetailHeight: CGFloat = 18
    static let quotaProgressHeight: CGFloat = 5
    /// Official 5h/7d rows that draw a progress bar. 8pt shorter than
    /// `quotaRowHeight` so the unused gap under the subtitle shrinks;
    /// title/subtitle/amount stay the same distance from the row top.
    static let quotaProgressRowHeight: CGFloat = 52
    static let quotaProgressResetOffset: CGFloat = quotaProgressHeight + metrics.subtitleProgressSpacing
    static let quotaProgressDetailOffset: CGFloat = quotaProgressResetOffset + quotaResetHeight + metrics.titleSubtitleSpacing
    /// Unused subtitle-to-bar slot removed from the original 60pt row.
    static var quotaProgressGapCompression: CGFloat {
        quotaRowHeight - quotaProgressRowHeight
    }
    /// Visible gap from a progress bar's top to the subtitle or link above it.
    static var quotaProgressTopGap: CGFloat {
        metrics.subtitleProgressSpacing
    }
    /// Space from a progress-row top to its title, matching official 5h/7d.
    static var quotaTitleTopInset: CGFloat {
        quotaProgressRowHeight - quotaProgressDetailOffset - quotaDetailHeight
    }
    /// Visible gap from a bar or 24h line to the next block's title.
    static var quotaVisibleBlockGap: CGFloat {
        metrics.sectionSpacing + quotaTitleTopInset
    }
    static var quotaProgressAmountOffset: CGFloat {
        max(0, quotaAmountOffset - quotaProgressGapCompression)
    }
    // An unavailable Reserve has no percentage to visualize. Keep enough
    // height for its two text lines and amount placeholder, but remove the
    // progress-bar slot and the gap that preceded it.
    static let lunaReserveNoProgressRowHeight: CGFloat = 42
    static let lunaReserveNoProgressAmountHeight: CGFloat = 42
    /// Ticket icon + title / window / expiry lines inside rounded chrome.
    /// Keep this taller than the two-line summary so the type title is not
    /// marquee-truncated.
    static let bankedResetDetailRowHeight: CGFloat = 72
    static let bankedResetExpandedDetailRowHeight: CGFloat = 96
    static let bankedResetTicketIconSize = CGSize(width: 31, height: 24)
    static let bankedResetTicketIconGap: CGFloat = 8
    static let bankedResetRemainingWidth: CGFloat = 120
    static let bankedResetChromeInset: CGFloat = 12
    static let bankedResetChromeCornerRadius: CGFloat = 10
    static let bankedResetTicketLineGap: CGFloat = 2
    /// Gap between the reset-card summary and the first ticket chrome.
    static let bankedResetSummaryDetailGap: CGFloat = 6
    /// The probability footer and reset-card summary use the same visible
    /// section spacing as the standard quota blocks.
    static var bankedResetProbabilitySummaryGap: CGFloat {
        metrics.subsectionSpacing
    }
    /// The second visible row under the title/primary-value band. Ordinary
    /// mode packs 24h+48h; strong-signal mode shows a hint or time progress.
    /// Source attribution is available through the primary value's hover link.
    static let bankedResetForecastLineGap: CGFloat = 2
    static let bankedResetForecastLineCount = 1
    static var bankedResetForecastMetricsWidth: CGFloat {
        contentWidth
    }
    static let bankedResetProbabilityHoverHintDelay: TimeInterval = 0.5

    static var bankedResetForecastSubtitleFont: NSFont {
        NSFont.systemFont(ofSize: quotaResetPointSize, weight: .regular)
    }

    static var bankedResetForecastNumericFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: quotaResetPointSize, weight: .regular)
    }

    static func bankedResetForecastLineHeight() -> CGFloat {
        let font = bankedResetForecastSubtitleFont
        return ceil(font.ascender - font.descender + 2)
    }

    static func bankedResetForecastExtraHeight() -> CGFloat {
        CGFloat(bankedResetForecastLineCount) * bankedResetForecastLineHeight()
    }

    static func forecastTextWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Left-to-right packing for `24h 24% · 48h 42%` on one subtitle row.
    /// Prefers spaced copy, then tightens gap/separator so longer locales
    /// still fit the metrics width without truncation.
    struct BankedResetForecastMetricsPacking: Equatable {
        static let preferredSeparator = " · "
        static let compactSeparator = "·"

        let gap: CGFloat
        let separator: String
        let prefix24Width: CGFloat
        let percent24Width: CGFloat
        let separatorWidth: CGFloat
        let prefix48Width: CGFloat
        let percent48Width: CGFloat

        var totalWidth: CGFloat {
            prefix24Width + gap + percent24Width
                + separatorWidth
                + prefix48Width + gap + percent48Width
        }

        static func make(
            prefix24: String,
            percent24: String,
            prefix48: String,
            percent48: String,
            availableWidth: CGFloat = OpenCodexCardLayout.bankedResetForecastMetricsWidth
        ) -> Self {
            let subtitleFont = OpenCodexCardLayout.bankedResetForecastSubtitleFont
            let numericFont = OpenCodexCardLayout.bankedResetForecastNumericFont
            let prefix24Width = OpenCodexCardLayout.forecastTextWidth(prefix24, font: subtitleFont)
            let percent24Width = OpenCodexCardLayout.forecastTextWidth(percent24, font: numericFont)
            let prefix48Width = OpenCodexCardLayout.forecastTextWidth(prefix48, font: subtitleFont)
            let percent48Width = OpenCodexCardLayout.forecastTextWidth(percent48, font: numericFont)
            let candidates: [(CGFloat, String)] = [
                (4, preferredSeparator),
                (2, preferredSeparator),
                (2, compactSeparator),
                (1, compactSeparator),
                (0, compactSeparator)
            ]
            for (gap, separator) in candidates {
                let separatorWidth = OpenCodexCardLayout.forecastTextWidth(
                    separator,
                    font: subtitleFont
                )
                let total = prefix24Width + gap + percent24Width
                    + separatorWidth
                    + prefix48Width + gap + percent48Width
                if total <= availableWidth {
                    return Self(
                        gap: gap,
                        separator: separator,
                        prefix24Width: prefix24Width,
                        percent24Width: percent24Width,
                        separatorWidth: separatorWidth,
                        prefix48Width: prefix48Width,
                        percent48Width: percent48Width
                    )
                }
            }
            let separatorWidth = OpenCodexCardLayout.forecastTextWidth(
                compactSeparator,
                font: subtitleFont
            )
            return Self(
                gap: 0,
                separator: compactSeparator,
                prefix24Width: prefix24Width,
                percent24Width: percent24Width,
                separatorWidth: separatorWidth,
                prefix48Width: prefix48Width,
                percent48Width: percent48Width
            )
        }
    }

    /// Amount box covering the title+subtitle band. 31pt digits center on
    /// those two lines instead of the 48pt quota amount that hangs into the
    /// progress-bar slot.
    static var bankedResetTextBandAmountHeight: CGFloat {
        quotaDetailOffset + quotaDetailHeight - quotaResetOffset
    }

    /// The probability section is one two-line band: the primary value spans
    /// the title and subtitle, while the reset frame carries the forecast
    /// subtitle or official hint.
    static func bankedResetProbabilityBlockHeight(
        includesForecastMetrics: Bool = true
    ) -> CGFloat {
        bankedResetTextBandAmountHeight
    }

    /// Large primary label for the strong-signal fallback. Shrinks just
    /// enough to stay inside the amount box so short localized tags do not
    /// overflow the 141pt column.
    static func bankedResetPrimaryLabelFont(for text: String) -> NSFont {
        let maxSize = quotaAmountPointSize
        let minSize: CGFloat = 17
        var size = maxSize
        while size > minSize {
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            if forecastTextWidth(text, font: font) <= amountWidth {
                return font
            }
            size -= 1
        }
        return NSFont.systemFont(ofSize: minSize, weight: .semibold)
    }

    /// Reset-card summary follows the probability footer directly. Its own
    /// quota-style title inset is reserved for standalone quota rows and is
    /// not part of this compact adjacent stack.
    static func bankedResetSummaryHeight() -> CGFloat {
        bankedResetTextBandAmountHeight
    }
    /// Detailed ticket list shows at most two full rows plus half of a
    /// third so leftover cards remain obvious. 1–2 cards stay unclipped.
    static let bankedResetVisibleTicketLimit: CGFloat = 2.5

    static func bankedResetTicketStackHeight(cardCount: Int, rowHeight: CGFloat = bankedResetDetailRowHeight) -> CGFloat {
        guard cardCount > 0 else { return 0 }
        return CGFloat(cardCount) * rowHeight
            + CGFloat(cardCount - 1) * metrics.ticketSpacing
    }

    static var bankedResetTicketViewportMaxHeight: CGFloat {
        bankedResetTicketViewportMaxHeight(rowHeight: bankedResetDetailRowHeight)
    }

    static func bankedResetTicketViewportMaxHeight(rowHeight: CGFloat) -> CGFloat {
        let fullVisibleRows = floor(bankedResetVisibleTicketLimit)
        let partialRow = bankedResetVisibleTicketLimit - fullVisibleRows
        return fullVisibleRows * rowHeight
            + fullVisibleRows * metrics.ticketSpacing
            + partialRow * rowHeight
    }

    static func bankedResetVisibleTicketStackHeight(cardCount: Int, rowHeight: CGFloat = bankedResetDetailRowHeight) -> CGFloat {
        min(
            bankedResetTicketStackHeight(cardCount: cardCount, rowHeight: rowHeight),
            bankedResetTicketViewportMaxHeight(rowHeight: rowHeight)
        )
    }

    static func bankedResetTicketsNeedScroll(cardCount: Int, rowHeight: CGFloat = bankedResetDetailRowHeight) -> Bool {
        bankedResetTicketStackHeight(cardCount: cardCount, rowHeight: rowHeight)
            > bankedResetTicketViewportMaxHeight(rowHeight: rowHeight) + 0.5
    }

    static func frames(
        for category: OpenCodexCardCategory,
        linkPrefixWidth: CGFloat = 62,
        includesBalanceSubtitle: Bool = true,
        includesBalanceRecharge: Bool = false,
        includesAccount: Bool = false,
        includesSubscription: Bool = false,
        subscriptionTextWidth: CGFloat? = nil,
        officialQuotaWindows: [OfficialQuotaWindow] = [],
        includesLunaReserve: Bool = false,
        includesLunaReserveProgress: Bool = true,
        lunaReserveInsertionIndex: Int? = nil,
        includesQuotaProgress: Bool = true,
        includesBankedReset: Bool = false,
        bankedResetCardCount: Int = 0,
        bankedResetDisplayMode: CodexBankedResetDisplayMode = .defaultValue,
        includesBankedResetNearestExpiry: Bool = false,
        includesBankedResetForecastMetrics: Bool = true,
        includesResetProbability: Bool? = nil,
        bankedResetTicketMetrics: [OpenCodexTicketTextMetrics] = []
    ) -> OpenCodexCardFrames {
        let showsProbability = includesResetProbability ?? includesBankedReset
        let hasWindows = !officialQuotaWindows.isEmpty
        if category == .quota,
           hasWindows || includesLunaReserve || includesBankedReset || showsProbability {
            return composedQuotaFrames(
                windows: officialQuotaWindows,
                includesAccount: includesAccount,
                includesSubscription: includesSubscription,
                subscriptionTextWidth: subscriptionTextWidth,
                includesLunaReserve: includesLunaReserve,
                includesLunaReserveProgress: includesLunaReserveProgress,
                lunaReserveInsertionIndex: lunaReserveInsertionIndex,
                includesQuotaProgress: includesQuotaProgress,
                includesBankedReset: includesBankedReset,
                bankedResetCardCount: bankedResetCardCount,
                bankedResetDisplayMode: bankedResetDisplayMode,
                includesBankedResetNearestExpiry: includesBankedResetNearestExpiry,
                includesBankedResetForecastMetrics: includesBankedResetForecastMetrics,
                includesResetProbability: showsProbability,
                bankedResetTicketMetrics: bankedResetTicketMetrics
            )
        }

        switch category {
        case .quota:
            let hasSubscription = includesAccount && includesSubscription
            let accountShift: CGFloat = includesAccount ? 19 : 0
            let textShift = includesQuotaProgress
                ? quotaProgressGapCompression
                : quotaRowHeight - lunaReserveNoProgressRowHeight
            let accountWidth = hasSubscription
                ? accountWidth(forSubscriptionTextWidth: subscriptionTextWidth)
                : contentWidth
            // Preserve the scalar compatibility profile, but construct its
            // local sections before exporting historical global frames.
            let headerOrigin = 75 - textShift
            let localHeader = OpenCodexAccountSectionFrames(
                title: CGRect(x: horizontalInset, y: accountShift, width: 189, height: 20),
                refreshTime: CGRect(x: refreshTimeX, y: accountShift + 1, width: 81, height: 17),
                account: includesAccount ? CGRect(x: horizontalInset, y: 0, width: accountWidth, height: 17) : nil,
                subscription: hasSubscription ? CGRect(x: subscriptionX, y: 0, width: subscriptionWidth, height: 17) : nil)
            let header = localHeader.offsetBy(dy: headerOrigin)
            let rowOrigin: CGFloat = includesQuotaProgress ? 8 : 0
            let row = quotaRowFrames(includesProgress: includesQuotaProgress, hasSubtitle: true,
                                     amountHeight: includesQuotaProgress ? quotaAmountHeight : lunaReserveNoProgressAmountHeight)
            let localRow = row.offsetBy(dy: -rowOrigin)
            return OpenCodexCardFrames(
                cardSize: CGSize(width: cardWidth, height: 102 + accountShift - textShift),
                title: header.title,
                refreshTime: header.refreshTime,
                account: header.account,
                subscription: header.subscription,
                quotaDetail: row.quotaDetail,
                reset: row.reset,
                amount: row.amount,
                progress: includesQuotaProgress ? row.progress : nil,
                linkPrefix: nil,
                link: nil,
                quotaRows: [row],
                lunaReserveRow: nil,
                bankedResetSummaryRow: nil,
                bankedResetProbabilityRow: nil,
                bankedResetForecastMetrics: nil,
                bankedResetForecastConfidence: nil,
                bankedResetDetailRows: [],
                bankedResetTicketViewport: nil,
                sectionLayouts: [
                    .init(id: .account,
                          frame: CGRect(x: 0, y: headerOrigin, width: cardWidth, height: 20 + accountShift),
                          row: nil, header: localHeader),
                    .init(id: .legacyQuota,
                          frame: CGRect(x: 0, y: rowOrigin, width: cardWidth, height: 47 - textShift + quotaDetailHeight - rowOrigin),
                          row: localRow)
                ]
            )
        case .balance:
            let linkWidth: CGFloat = linkPrefixWidth == 62 ? 148 : 136
            let linkX: CGFloat = horizontalInset + linkPrefixWidth - 1
            let textShift = includesQuotaProgress
                ? quotaProgressGapCompression
                : quotaRowHeight - lunaReserveNoProgressRowHeight
            let inlineRecharge = includesBalanceRecharge && !includesBalanceSubtitle
            let subtitleShift: CGFloat = includesBalanceSubtitle || inlineRecharge ? 0 : 8
            let rechargeShift: CGFloat = includesBalanceRecharge && !inlineRecharge ? 25 : 0
            let row = quotaRowFrames(includesProgress: includesQuotaProgress,
                                     hasSubtitle: includesBalanceSubtitle || includesBalanceRecharge)
            return OpenCodexCardFrames(
                cardSize: CGSize(width: cardWidth, height: 102 - textShift - subtitleShift + rechargeShift),
                title: CGRect(x: horizontalInset, y: 75 - textShift - subtitleShift + rechargeShift, width: 189, height: 20),
                refreshTime: CGRect(x: refreshTimeX, y: 76 - textShift - subtitleShift + rechargeShift, width: 81, height: 17),
                account: nil,
                subscription: nil,
                quotaDetail: row.quotaDetail.offsetBy(dx: 0, dy: rechargeShift),
                reset: nil,
                amount: row.amount.offsetBy(dx: 0, dy: rechargeShift),
                progress: includesQuotaProgress ? row.progress : nil,
                linkPrefix: includesBalanceSubtitle ? CGRect(
                    x: horizontalInset,
                    y: 28 - textShift + rechargeShift,
                    width: linkPrefixWidth,
                    height: 17
                ) : nil,
                link: includesBalanceSubtitle ? CGRect(x: linkX, y: 28 - textShift + rechargeShift, width: linkWidth, height: 17) : nil,
                quotaRows: [],
                lunaReserveRow: nil,
                bankedResetSummaryRow: nil,
                bankedResetProbabilityRow: nil,
                bankedResetForecastMetrics: nil,
                bankedResetForecastConfidence: nil,
                bankedResetDetailRows: [],
                bankedResetTicketViewport: nil,
                balanceRecharge: includesBalanceRecharge
                    ? CGRect(x: horizontalInset, y: inlineRecharge ? row.reset.minY : (includesQuotaProgress ? 18 : 0), width: contentWidth, height: quotaResetHeight) : nil
            )
        }
    }

    /// Shared body slots for the scalar official quota card and balance card.
    static func quotaRowFrames(includesProgress: Bool, hasSubtitle: Bool, amountHeight: CGFloat = quotaAmountHeight) -> OpenCodexQuotaRowFrames {
        let textShift = includesProgress ? quotaProgressGapCompression
            : quotaRowHeight - lunaReserveNoProgressRowHeight
        return OpenCodexQuotaRowFrames(
            quotaDetail: CGRect(x: horizontalInset, y: 47 - textShift - (hasSubtitle ? 0 : 8),
                                width: 128, height: quotaDetailHeight),
            reset: CGRect(x: horizontalInset, y: 28 - textShift, width: 128, height: quotaResetHeight),
            amount: CGRect(x: amountX, y: max(0, 18 - textShift), width: amountWidth, height: amountHeight),
            progress: includesProgress
                ? CGRect(x: horizontalInset, y: 8, width: contentWidth, height: quotaProgressHeight) : .zero)
    }

    private static func composedQuotaFrames(
        windows: [OfficialQuotaWindow],
        includesAccount: Bool,
        includesSubscription: Bool,
        subscriptionTextWidth: CGFloat?,
        includesLunaReserve: Bool,
        includesLunaReserveProgress: Bool,
        lunaReserveInsertionIndex: Int?,
        includesQuotaProgress: Bool,
        includesBankedReset: Bool,
        bankedResetCardCount: Int,
        bankedResetDisplayMode: CodexBankedResetDisplayMode,
        includesBankedResetNearestExpiry: Bool,
        includesBankedResetForecastMetrics: Bool,
        includesResetProbability: Bool,
        bankedResetTicketMetrics: [OpenCodexTicketTextMetrics]
    ) -> OpenCodexCardFrames {
        let windowCount = windows.count
        let rowHeight = includesQuotaProgress ? quotaProgressRowHeight : lunaReserveNoProgressRowHeight
        let windowContentShift = includesQuotaProgress
            ? 0
            : quotaRowHeight - lunaReserveNoProgressRowHeight
        let windowDetailOffset = includesQuotaProgress
            ? quotaProgressDetailOffset
            : quotaDetailOffset
        let windowResetOffset = includesQuotaProgress
            ? quotaProgressResetOffset
            : quotaResetOffset
        let ticketGap = metrics.ticketSpacing
        let bottomInset = quotaBottomInset
        let titleGap = quotaTitleGap
        let accountShift: CGFloat = includesAccount ? 19 : 0
        let reserveRowHeight = includesLunaReserve
            ? (includesLunaReserveProgress ? quotaProgressRowHeight : lunaReserveNoProgressRowHeight)
            : 0
        let bankedResetIsDetailed = includesBankedReset && bankedResetDisplayMode == .detailed
        let bankedDetailCount = bankedResetIsDetailed ? max(0, bankedResetCardCount) : 0
        let showsForecastMetrics = includesResetProbability && includesBankedResetForecastMetrics
        let forecastLineHeight = bankedResetForecastLineHeight()
        let probabilityBlockHeight = includesResetProbability
            ? bankedResetProbabilityBlockHeight(
                includesForecastMetrics: includesBankedResetForecastMetrics
            )
            : 0
        let cardSummaryHeight = includesBankedReset
            ? bankedResetSummaryHeight()
            : 0
        let ticketContentMaxX = cardWidth - horizontalInset - bankedResetChromeInset
        let ticketTextX = horizontalInset + bankedResetChromeInset
            + bankedResetTicketIconSize.width + bankedResetTicketIconGap
        let fullTicketTextWidth = ticketContentMaxX - ticketTextX
        let ticketInputs = (0..<bankedDetailCount).map { index -> (mode: OpenCodexTicketLayoutMode, amountWidth: CGFloat, height: CGFloat) in
            guard bankedResetTicketMetrics.indices.contains(index) else {
                return (.compact, bankedResetRemainingWidth, bankedResetDetailRowHeight)
            }
            let measured = bankedResetTicketMetrics[index]
            let textWidth = measured.windowWidth
            // Preserve the existing column when it fits; otherwise reclaim unused
            // countdown space before deciding that an additional line is needed.
            let amountWidth = textWidth <= fullTicketTextWidth - bankedResetRemainingWidth - 6
                && measured.amountWidth <= bankedResetRemainingWidth
                ? bankedResetRemainingWidth : measured.amountWidth
            let expanded = textWidth + amountWidth + 6 > fullTicketTextWidth
            return (expanded ? .expanded : .compact, amountWidth,
                    expanded ? bankedResetExpandedDetailRowHeight : bankedResetDetailRowHeight)
        }
        let ticketHeights = ticketInputs.map(\.height)
        let ticketStackHeight = ticketHeights.reduce(0, +)
            + CGFloat(max(0, bankedDetailCount - 1)) * ticketGap
        // The viewport shows the first two complete tickets and half of the third,
        // including mixed compact/expanded lists in their displayed order.
        let ticketViewportHeight = ticketHeights.prefix(2).reduce(0, +)
            + (ticketHeights.count > 2 ? ticketHeights[2] / 2 + ticketGap * 2
               : CGFloat(max(0, ticketHeights.count - 1)) * ticketGap)
        let bankedVisibleTicketStackHeight = min(ticketStackHeight, ticketViewportHeight)
        let bankedDetailBlockHeight = bankedDetailCount > 0
            ? bankedVisibleTicketStackHeight + bankedResetSummaryDetailGap
            : 0
        let reserveInsertionIndex: Int? = {
            guard includesLunaReserve else { return nil }
            if let lunaReserveInsertionIndex {
                return min(max(0, lunaReserveInsertionIndex), windowCount)
            }
            return windows.firstIndex(where: { $0.kind == .fiveHour }).map { $0 + 1 } ?? 0
        }()
        func metricRow(detailOffset: CGFloat, resetOffset: CGFloat,
                       amountOffset: CGFloat, amountHeight: CGFloat, progress: Bool) -> OpenCodexQuotaRowFrames {
            OpenCodexQuotaRowFrames(
                quotaDetail: CGRect(x: horizontalInset, y: detailOffset, width: 128, height: quotaDetailHeight),
                reset: CGRect(x: horizontalInset, y: resetOffset, width: 128, height: quotaResetHeight),
                amount: CGRect(x: amountX, y: amountOffset, width: amountWidth, height: amountHeight),
                progress: progress ? CGRect(x: horizontalInset, y: 0, width: contentWidth, height: quotaProgressHeight) : .zero
            )
        }
        let localQuotaRow = metricRow(
            detailOffset: windowDetailOffset - windowContentShift,
            resetOffset: windowResetOffset - windowContentShift,
            amountOffset: windowResetOffset - windowContentShift,
            amountHeight: bankedResetTextBandAmountHeight, progress: includesQuotaProgress)
        let reserveContentShift = includesLunaReserveProgress
            ? 0
            : quotaRowHeight - lunaReserveNoProgressRowHeight
        let reserveDetailOffset = includesLunaReserveProgress
            ? quotaProgressDetailOffset
            : quotaDetailOffset
        let reserveResetOffset = includesLunaReserveProgress
            ? quotaProgressResetOffset
            : quotaResetOffset
        let reserveAmountOffset = includesLunaReserveProgress
            ? quotaProgressAmountOffset
            : quotaAmountOffset
        let reserveAmountHeight = includesLunaReserveProgress
            ? quotaAmountHeight
            : lunaReserveNoProgressAmountHeight
        let localReserveRow = includesLunaReserve
            ? metricRow(
                        detailOffset: reserveDetailOffset - reserveContentShift,
                        resetOffset: reserveResetOffset - reserveContentShift,
                        amountOffset: max(0, reserveAmountOffset - reserveContentShift),
                        amountHeight: reserveAmountHeight, progress: includesLunaReserveProgress)
            : nil
        // Build local content first; the root inserts only adjacent spacing.
        var body: [(id: OpenCodexOverviewSectionID, height: CGFloat, row: OpenCodexQuotaRowFrames?)] =
            windows.enumerated().map { (.quota($0.element, index: $0.offset), rowHeight, localQuotaRow) }
        if let reserveInsertionIndex, let localReserveRow {
            body.insert((.lunaReserve, reserveRowHeight, localReserveRow), at: reserveInsertionIndex)
        }
        func bandRow(y: CGFloat, showsReset: Bool) -> OpenCodexQuotaRowFrames {
            metricRow(
                      detailOffset: y + quotaDetailOffset - quotaResetOffset,
                      resetOffset: y, amountOffset: y,
                      amountHeight: bankedResetTextBandAmountHeight, progress: false)
                .withResetVisible(showsReset)
        }
        if includesResetProbability {
            body.append((.resetProbability, probabilityBlockHeight, bandRow(y: 0, showsReset: true)))
        }
        if includesBankedReset {
            body.append((.bankedReset, cardSummaryHeight + bankedDetailBlockHeight,
                         bandRow(y: bankedDetailBlockHeight, showsReset: includesBankedResetNearestExpiry)))
        }
        func spacing(from: OpenCodexOverviewSectionID, to: OpenCodexOverviewSectionID) -> CGFloat {
            if from == .resetProbability && to == .bankedReset { return metrics.subsectionSpacing }
            if to == .resetProbability || to == .bankedReset { return metrics.sectionSpacing }
            return metrics.quotaRowSpacing
        }
        let rowAreaHeight = body.enumerated().reduce(CGFloat.zero) { sum, item in
            sum + item.element.height + (item.offset + 1 < body.count
                ? spacing(from: item.element.id, to: body[item.offset + 1].id) : 0)
        }
        let baseTitleY = bottomInset + rowAreaHeight + titleGap
        let titleY = baseTitleY + accountShift
        let cardHeight = titleY + 20 + 7
        let hasSubscription = includesAccount && includesSubscription
        let accountWidth = hasSubscription ? accountWidth(forSubscriptionTextWidth: subscriptionTextWidth) : contentWidth
        let localHeader = OpenCodexAccountSectionFrames(
            title: CGRect(x: horizontalInset, y: accountShift, width: 189, height: 20),
            refreshTime: CGRect(x: refreshTimeX, y: accountShift + 1, width: 81, height: 17),
            account: includesAccount ? CGRect(x: horizontalInset, y: 0, width: accountWidth, height: 17) : nil,
            subscription: hasSubscription ? CGRect(x: subscriptionX, y: 0, width: subscriptionWidth, height: 17) : nil)
        let header = localHeader.offsetBy(dy: baseTitleY)
        var sections = [OpenCodexOverviewSectionLayout(id: .account,
            frame: CGRect(x: 0, y: baseTitleY, width: cardWidth, height: 20 + accountShift), row: nil, header: localHeader)]
        var cursor = bottomInset + rowAreaHeight
        for (index, block) in body.enumerated() {
            cursor -= block.height
            sections.append(.init(id: block.id,
                frame: CGRect(x: 0, y: cursor, width: cardWidth, height: block.height), row: block.row))
            if index + 1 < body.count { cursor -= spacing(from: block.id, to: body[index + 1].id) }
        }
        let rows = windows.enumerated().compactMap { index, window in
            sections.first { $0.id == .quota(window, index: index) }?.cardRow
        }
        let lunaReserveRow = sections.first { $0.id == .lunaReserve }?.cardRow
        let bankedResetSummaryRow = sections.first { $0.id == .bankedReset }?.cardRow
        let bankedResetProbabilityRow = sections.first { $0.id == .resetProbability }?.cardRow
        let probabilityRowY = sections.first { $0.id == .resetProbability }?.frame.minY ?? 0
        let bankedResetForecastMetrics = showsForecastMetrics
            ? CGRect(
                x: horizontalInset,
                y: probabilityRowY,
                width: 128,
                height: forecastLineHeight
            )
            : nil
        /// Document-local frames for every ticket, including unscrolled 1–2 lists.
    /// Never union these with card-coordinate section placements.
    let bankedResetDetailRows: [OpenCodexQuotaRowFrames] = {
            guard includesBankedReset, bankedDetailCount > 0 else { return [] }
            let iconSize = bankedResetTicketIconSize
            let chromeInset = bankedResetChromeInset
            let contentMinX = horizontalInset + chromeInset
            let contentMaxX = cardWidth - horizontalInset - chromeInset
            let textX = contentMinX + iconSize.width + bankedResetTicketIconGap
            let lineWidth = max(0, contentMaxX - textX)
            let lineGap = bankedResetTicketLineGap
            return (0..<bankedDetailCount).map { index in
                let input = ticketInputs[index]
                let ticketLayoutMode = input.mode
                let bankedDetailHeight = input.height
                let remainingX = contentMaxX - input.amountWidth
                let titleWidth = max(0, remainingX - textX - 6)
                let textBlockHeight = ticketLayoutMode == .expanded
                    ? quotaDetailHeight * 2 + quotaResetHeight * 2 + lineGap * 3
                    : quotaDetailHeight + quotaResetHeight * 2 + lineGap * 2
                // All lists use document-local coordinates, including 1–2 tickets.
                let originY: CGFloat = 0
                let y = originY
                    + ticketHeights.dropFirst(index + 1).reduce(0, +)
                    + CGFloat(bankedDetailCount - 1 - index) * ticketGap
                let textBlockY = y + (bankedDetailHeight - textBlockHeight) / 2
                let expiryY = ticketLayoutMode == .expanded
                    ? textBlockY + quotaDetailHeight + lineGap : textBlockY
                let windowY = expiryY + quotaResetHeight + lineGap
                let titleY = windowY + quotaResetHeight + lineGap
                let amountY = ticketLayoutMode == .expanded
                    ? textBlockY
                    : windowY + (quotaResetHeight - quotaDetailHeight) / 2
                let iconY = y + (bankedDetailHeight - iconSize.height) / 2
                return OpenCodexQuotaRowFrames(
                    quotaDetail: CGRect(
                        x: textX,
                        y: titleY,
                        width: lineWidth,
                        height: quotaDetailHeight
                    ),
                    reset: CGRect(
                        x: textX,
                        y: expiryY,
                        width: lineWidth,
                        height: quotaResetHeight
                    ),
                    amount: CGRect(
                        x: ticketLayoutMode == .expanded ? textX : remainingX,
                        y: amountY,
                        width: ticketLayoutMode == .expanded ? lineWidth : input.amountWidth,
                        height: quotaDetailHeight
                    ),
                    progress: .zero,
                    icon: CGRect(
                        x: contentMinX,
                        y: iconY,
                        width: iconSize.width,
                        height: iconSize.height
                    ),
                    window: CGRect(
                        x: textX,
                        y: windowY,
                        width: ticketLayoutMode == .expanded ? lineWidth : titleWidth,
                        height: quotaResetHeight
                    ),
                    chrome: CGRect(
                        x: horizontalInset,
                        y: y,
                        width: contentWidth,
                        height: bankedDetailHeight
                    )
                )
            }
        }()

        return OpenCodexCardFrames(
            cardSize: CGSize(width: cardWidth, height: cardHeight),
            title: header.title,
            refreshTime: header.refreshTime,
            account: header.account,
            subscription: header.subscription,
            quotaDetail: .zero,
            reset: nil,
            amount: .zero,
            progress: nil,
            linkPrefix: nil,
            link: nil,
            quotaRows: rows,
            lunaReserveRow: lunaReserveRow,
            bankedResetSummaryRow: bankedResetSummaryRow,
            bankedResetProbabilityRow: bankedResetProbabilityRow,
            bankedResetForecastMetrics: bankedResetForecastMetrics,
            bankedResetForecastConfidence: nil,
            bankedResetDetailRows: bankedResetDetailRows,
            bankedResetTicketViewport: bankedDetailCount > 0
                ? CGRect(
                    x: 0,
                    y: sections.first { $0.id == .bankedReset }!.frame.minY,
                    width: cardWidth,
                    height: bankedVisibleTicketStackHeight
                )
                : nil,
            sectionLayouts: sections
        )
    }

    /// The subscription label is right-aligned within its fixed layout frame.
    /// When its rendered width is known, let the account marquee use the empty
    /// leading part of that frame and end a small safety gap before the
    /// subscription text itself.
    /// Keeping the unmeasured fallback preserves the geometry-only layout seam.
    static func accountWidth(forSubscriptionTextWidth textWidth: CGFloat?) -> CGFloat {
        guard let textWidth else { return accountWidthWithSubscription }

        let clampedTextWidth = min(max(0, textWidth), subscriptionWidth)
        let subscriptionTextMinX = subscriptionX + subscriptionWidth - clampedTextWidth
        return max(
            0,
            min(
                contentWidth,
                subscriptionTextMinX
                    - subscriptionTextSafetyGap
                    - horizontalInset
            )
        )
    }
}
