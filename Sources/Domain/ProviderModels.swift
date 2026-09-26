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

    init(
        id: String,
        name: String = "",
        isOfficial: Bool,
        query: BalanceQuery?,
        officialAccessToken: String?,
        websiteURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.isOfficial = isOfficial
        self.query = query
        self.officialAccessToken = officialAccessToken
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
    /// Extra line under the data-source subtitle. Ordinary mode packs
    /// 24h+48h; strong-signal mode uses the same slot for the gray
    /// official-hint line.
    let bankedResetForecastMetrics: CGRect?
    let bankedResetForecastConfidence: CGRect?
    let bankedResetDetailRows: [OpenCodexQuotaRowFrames]
    /// Host-coordinate clip for the detailed ticket list. Nil when the
    /// overview has no tickets. 1–2 tickets fill this rect; 3+ clip to
    /// `bankedResetTicketViewportMaxHeight` and scroll inside it.
    let bankedResetTicketViewport: CGRect?
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

enum OpenCodexCardLayout {
    static let cardWidth: CGFloat = 304
    static let horizontalInset: CGFloat = 14
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
    static let quotaRowGap: CGFloat = 14
    static let quotaBottomInset: CGFloat = 8
    static let quotaTitleGap: CGFloat = 11
    static let quotaAmountOffset: CGFloat = 10
    static let quotaResetOffset: CGFloat = 20
    static let quotaDetailOffset: CGFloat = 39
    static let quotaAmountHeight: CGFloat = 48
    static let quotaResetHeight: CGFloat = 17
    static let quotaDetailHeight: CGFloat = 18
    static let quotaProgressHeight: CGFloat = 5
    /// Official 5h/7d rows that draw a progress bar. 8pt shorter than
    /// `quotaRowHeight` so the unused gap under the subtitle shrinks;
    /// title/subtitle/amount stay the same distance from the row top.
    static let quotaProgressRowHeight: CGFloat = 52
    static let quotaProgressResetOffset: CGFloat = 12
    static let quotaProgressDetailOffset: CGFloat = 31
    /// Unused subtitle-to-bar slot removed from the original 60pt row.
    static var quotaProgressGapCompression: CGFloat {
        quotaRowHeight - quotaProgressRowHeight
    }
    /// Visible gap from a progress bar's top to the subtitle or link above it.
    static var quotaProgressTopGap: CGFloat {
        quotaProgressResetOffset - quotaProgressHeight
    }
    /// Space from a progress-row top to its title, matching official 5h/7d.
    static var quotaTitleTopInset: CGFloat {
        quotaProgressRowHeight - quotaProgressDetailOffset - quotaDetailHeight
    }
    /// Visible gap from a bar or 24h line to the next block's title.
    static var quotaVisibleBlockGap: CGFloat {
        quotaRowGap + quotaTitleTopInset
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
    static let bankedResetTicketIconSize = CGSize(width: 31, height: 24)
    static let bankedResetTicketIconGap: CGFloat = 8
    static let bankedResetRemainingWidth: CGFloat = 120
    static let bankedResetChromeInset: CGFloat = 8
    static let bankedResetChromeCornerRadius: CGFloat = 10
    /// Gap between the reset-card summary and the first ticket chrome.
    static let bankedResetSummaryDetailGap: CGFloat = 6
    /// One extra line under the data-source subtitle. Ordinary mode packs
    /// 24h+48h; strong-signal mode draws the gray official-hint copy here.
    /// The data source sits in the amount's reset slot. Confidence is not
    /// part of the menu block. Longer locales pack 24h+48h by tightening
    /// gap/separator.
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

    /// Two-line text band, plus the extra metrics/hint line when that slot
    /// is visible. `quotaTitleTopInset` keeps the next-block title 17pt below
    /// the bar or extra line, matching 5h progress → 7-day title.
    static func bankedResetProbabilityBlockHeight(
        includesForecastMetrics: Bool = true
    ) -> CGFloat {
        let metricsHeight = includesForecastMetrics
            ? bankedResetForecastLineGap + bankedResetForecastExtraHeight()
            : 0
        return quotaTitleTopInset
            + bankedResetTextBandAmountHeight
            + metricsHeight
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

    /// Reset-card header is the same two-line band plus the 3pt title inset.
    /// Tickets sit 6pt below the subtitle.
    static func bankedResetSummaryHeight() -> CGFloat {
        quotaTitleTopInset + bankedResetTextBandAmountHeight
    }
    /// Detailed ticket list shows at most two full rows plus half of a
    /// third so leftover cards remain obvious. 1–2 cards stay unclipped.
    static let bankedResetVisibleTicketLimit: CGFloat = 2.5

    static func bankedResetTicketStackHeight(cardCount: Int) -> CGFloat {
        guard cardCount > 0 else { return 0 }
        return CGFloat(cardCount) * bankedResetDetailRowHeight
            + CGFloat(cardCount - 1) * quotaRowGap
    }

    static var bankedResetTicketViewportMaxHeight: CGFloat {
        let fullVisibleRows = floor(bankedResetVisibleTicketLimit)
        let partialRow = bankedResetVisibleTicketLimit - fullVisibleRows
        return fullVisibleRows * bankedResetDetailRowHeight
            + fullVisibleRows * quotaRowGap
            + partialRow * bankedResetDetailRowHeight
    }

    static func bankedResetVisibleTicketStackHeight(cardCount: Int) -> CGFloat {
        min(
            bankedResetTicketStackHeight(cardCount: cardCount),
            bankedResetTicketViewportMaxHeight
        )
    }

    static func bankedResetTicketsNeedScroll(cardCount: Int) -> Bool {
        bankedResetTicketStackHeight(cardCount: cardCount)
            > bankedResetTicketViewportMaxHeight + 0.5
    }

    static func frames(
        for category: OpenCodexCardCategory,
        linkPrefixWidth: CGFloat = 62,
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
        includesBankedResetForecastMetrics: Bool = true
    ) -> OpenCodexCardFrames {
        let recognizedWindowCount = officialQuotaWindows.filter { $0.kind != .other }.count
        if category == .quota,
           recognizedWindowCount > 1 || includesLunaReserve || includesBankedReset {
            return expandedQuotaFrames(
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
                includesBankedResetForecastMetrics: includesBankedResetForecastMetrics
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
            return OpenCodexCardFrames(
                cardSize: CGSize(width: cardWidth, height: 102 + accountShift - textShift),
                title: CGRect(x: horizontalInset, y: 75 + accountShift - textShift, width: 189, height: 20),
                refreshTime: CGRect(x: refreshTimeX, y: 76 + accountShift - textShift, width: 81, height: 17),
                account: includesAccount
                    ? CGRect(x: horizontalInset, y: 75 - textShift, width: accountWidth, height: 17)
                    : nil,
                subscription: hasSubscription
                    ? CGRect(
                        x: subscriptionX,
                        y: 75 - textShift,
                        width: subscriptionWidth,
                        height: 17
                    )
                    : nil,
                quotaDetail: CGRect(
                    x: horizontalInset,
                    y: 47 - textShift,
                    width: 128,
                    height: quotaDetailHeight
                ),
                reset: CGRect(
                    x: horizontalInset,
                    y: 28 - textShift,
                    width: 128,
                    height: quotaResetHeight
                ),
                amount: CGRect(
                    x: amountX,
                    y: max(0, 18 - textShift),
                    width: amountWidth,
                    height: includesQuotaProgress ? quotaAmountHeight : lunaReserveNoProgressAmountHeight
                ),
                progress: includesQuotaProgress
                    ? CGRect(
                        x: horizontalInset,
                        y: 8,
                        width: contentWidth,
                        height: quotaProgressHeight
                    )
                    : nil,
                linkPrefix: nil,
                link: nil,
                quotaRows: [],
                lunaReserveRow: nil,
                bankedResetSummaryRow: nil,
                bankedResetProbabilityRow: nil,
                bankedResetForecastMetrics: nil,
                bankedResetForecastConfidence: nil,
                bankedResetDetailRows: [],
                bankedResetTicketViewport: nil
            )
        case .balance:
            let linkWidth: CGFloat = linkPrefixWidth == 62 ? 148 : 136
            let linkX: CGFloat = horizontalInset + linkPrefixWidth - 1
            let textShift = includesQuotaProgress
                ? quotaProgressGapCompression
                : quotaRowHeight - lunaReserveNoProgressRowHeight
            return OpenCodexCardFrames(
                cardSize: CGSize(width: cardWidth, height: 102 - textShift),
                title: CGRect(x: horizontalInset, y: 75 - textShift, width: 189, height: 20),
                refreshTime: CGRect(x: refreshTimeX, y: 76 - textShift, width: 81, height: 17),
                account: nil,
                subscription: nil,
                quotaDetail: CGRect(x: horizontalInset, y: 47 - textShift, width: 128, height: 18),
                reset: nil,
                amount: CGRect(
                    x: amountX,
                    y: max(0, 18 - textShift),
                    width: amountWidth,
                    // Keep the 48pt box when the progress slot collapses.
                    // A 42pt box would leave its top 5pt below the detail row.
                    height: 48
                ),
                progress: includesQuotaProgress
                    ? CGRect(x: horizontalInset, y: 8, width: contentWidth, height: quotaProgressHeight)
                    : nil,
                linkPrefix: CGRect(
                    x: horizontalInset,
                    y: 28 - textShift,
                    width: linkPrefixWidth,
                    height: 17
                ),
                link: CGRect(x: linkX, y: 28 - textShift, width: linkWidth, height: 17),
                quotaRows: [],
                lunaReserveRow: nil,
                bankedResetSummaryRow: nil,
                bankedResetProbabilityRow: nil,
                bankedResetForecastMetrics: nil,
                bankedResetForecastConfidence: nil,
                bankedResetDetailRows: [],
                bankedResetTicketViewport: nil
            )
        }
    }

    private static func expandedQuotaFrames(
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
        includesBankedResetForecastMetrics: Bool
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
        let rowGap = quotaRowGap
        let bottomInset = quotaBottomInset
        let titleGap = quotaTitleGap
        let accountShift: CGFloat = includesAccount ? 19 : 0
        let reserveRowHeight = includesLunaReserve
            ? (includesLunaReserveProgress ? quotaProgressRowHeight : lunaReserveNoProgressRowHeight)
            : 0
        let reserveGap = includesLunaReserve && windowCount > 0 ? rowGap : 0
        let bankedResetIsDetailed = includesBankedReset && bankedResetDisplayMode == .detailed
        let bankedDetailCount = bankedResetIsDetailed ? max(0, bankedResetCardCount) : 0
        let showsForecastMetrics = includesBankedReset && includesBankedResetForecastMetrics
        let forecastExtraHeight = showsForecastMetrics
            ? bankedResetForecastLineGap + bankedResetForecastExtraHeight()
            : 0
        let forecastLineHeight = bankedResetForecastLineHeight()
        let probabilityBlockHeight = includesBankedReset
            ? bankedResetProbabilityBlockHeight(
                includesForecastMetrics: includesBankedResetForecastMetrics
            )
            : 0
        let cardSummaryHeight = includesBankedReset
            ? bankedResetSummaryHeight()
            : 0
        let probabilityCardGap = includesBankedReset ? rowGap : 0
        let bankedDetailHeight = bankedResetDetailRowHeight
        let bankedVisibleTicketStackHeight = bankedResetVisibleTicketStackHeight(
            cardCount: bankedDetailCount
        )
        let bankedTicketsNeedScroll = bankedResetTicketsNeedScroll(cardCount: bankedDetailCount)
        let bankedDetailBlockHeight = bankedDetailCount > 0
            ? bankedVisibleTicketStackHeight + bankedResetSummaryDetailGap
            : 0
        let bankedBlockHeight = probabilityBlockHeight
            + probabilityCardGap
            + cardSummaryHeight
            + bankedDetailBlockHeight
        let bankedLeadingGap = includesBankedReset
            && (windowCount > 0 || includesLunaReserve) ? rowGap : 0
        let quotaLift = bankedBlockHeight + bankedLeadingGap
        let rowAreaHeight = CGFloat(windowCount) * rowHeight
            + CGFloat(max(0, windowCount - 1)) * rowGap
            + reserveGap
            + reserveRowHeight
            + quotaLift
        let baseTitleY = bottomInset + rowAreaHeight + titleGap
        let titleY = baseTitleY + accountShift
        let cardHeight = titleY + 20 + 7
        let hasSubscription = includesAccount && includesSubscription
        let accountWidth = hasSubscription
            ? accountWidth(forSubscriptionTextWidth: subscriptionTextWidth)
            : contentWidth
        let reserveInsertionIndex: Int? = {
            guard includesLunaReserve else { return nil }
            if let lunaReserveInsertionIndex {
                return min(max(0, lunaReserveInsertionIndex), windowCount)
            }
            guard let fiveHourIndex = windows.firstIndex(where: { $0.kind == .fiveHour }) else {
                // Pro accounts currently expose only the 7-day window, so the
                // Reserve belongs immediately above that first standard row.
                return 0
            }
            return fiveHourIndex + 1
        }()
        let reserveRowsBelow: Int = {
            guard includesLunaReserve else { return 0 }
            guard let reserveInsertionIndex else { return windowCount }
            return windowCount - reserveInsertionIndex
        }()
        let rows = windows.enumerated().map { index, _ in
            let yWithoutReserve = bottomInset
                + quotaLift
                + CGFloat(windowCount - 1 - index) * (rowHeight + rowGap)
            let isAboveReserve = reserveInsertionIndex.map { index < $0 } ?? false
            let y = yWithoutReserve
                + (isAboveReserve ? reserveRowHeight + reserveGap : 0)
            return OpenCodexQuotaRowFrames(
                quotaDetail: CGRect(
                    x: horizontalInset,
                    y: y + windowDetailOffset - windowContentShift,
                    width: 128,
                    height: quotaDetailHeight
                ),
                reset: CGRect(
                    x: horizontalInset,
                    y: y + windowResetOffset - windowContentShift,
                    width: 128,
                    height: quotaResetHeight
                ),
                // Same title+subtitle band as 重置概率. Progress stays at row origin.
                amount: CGRect(
                    x: amountX,
                    y: y + windowResetOffset - windowContentShift,
                    width: amountWidth,
                    height: bankedResetTextBandAmountHeight
                ),
                progress: includesQuotaProgress
                    ? CGRect(
                        x: horizontalInset,
                        y: y,
                        width: contentWidth,
                        height: quotaProgressHeight
                    )
                    : .zero
            )
        }
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
        let lunaReserveRow = includesLunaReserve
            ? OpenCodexQuotaRowFrames(
                quotaDetail: CGRect(
                    x: horizontalInset,
                    y: bottomInset
                        + quotaLift
                        + CGFloat(reserveRowsBelow) * (rowHeight + rowGap)
                        + reserveDetailOffset
                        - reserveContentShift,
                    width: 128,
                    height: quotaDetailHeight
                ),
                reset: CGRect(
                    x: horizontalInset,
                    y: bottomInset
                        + quotaLift
                        + CGFloat(reserveRowsBelow) * (rowHeight + rowGap)
                        + reserveResetOffset
                        - reserveContentShift,
                    width: 128,
                    height: quotaResetHeight
                ),
                amount: CGRect(
                    x: amountX,
                    y: bottomInset
                        + quotaLift
                        + CGFloat(reserveRowsBelow) * (rowHeight + rowGap)
                        + max(0, reserveAmountOffset - reserveContentShift),
                    width: amountWidth,
                    height: reserveAmountHeight
                ),
                progress: includesLunaReserveProgress
                    ? CGRect(
                        x: horizontalInset,
                        y: bottomInset
                            + quotaLift
                            + CGFloat(reserveRowsBelow) * (rowHeight + rowGap),
                        width: contentWidth,
                        height: quotaProgressHeight
                    )
                    : .zero
            )
            : nil
        let cardSummaryY = bottomInset + bankedDetailBlockHeight
        let probabilityBottomY = cardSummaryY + cardSummaryHeight + probabilityCardGap
        let probabilityRowY = probabilityBottomY + forecastExtraHeight
        // Row origin is the subtitle bottom. Title, subtitle, and amount
        // keep the same two-line relationship; the unused progress-bar
        // slot is not part of the block height.
        func quotaBandFrames(rowY: CGFloat, showsReset: Bool) -> OpenCodexQuotaRowFrames {
            OpenCodexQuotaRowFrames(
                quotaDetail: CGRect(
                    x: horizontalInset,
                    y: rowY + quotaDetailOffset - quotaResetOffset,
                    width: 128,
                    height: quotaDetailHeight
                ),
                reset: showsReset
                    ? CGRect(
                        x: horizontalInset,
                        y: rowY,
                        width: 128,
                        height: quotaResetHeight
                    )
                    : .zero,
                amount: CGRect(
                    x: amountX,
                    y: rowY,
                    width: amountWidth,
                    height: bankedResetTextBandAmountHeight
                ),
                progress: .zero
            )
        }
        let summaryShowsExpiry = includesBankedReset && includesBankedResetNearestExpiry
        let bankedResetSummaryRow = includesBankedReset
            ? quotaBandFrames(rowY: cardSummaryY, showsReset: summaryShowsExpiry)
            : nil
        let bankedResetProbabilityRow = includesBankedReset
            ? quotaBandFrames(rowY: probabilityRowY, showsReset: true)
            : nil
        let bankedResetForecastMetrics = showsForecastMetrics
            ? CGRect(
                x: horizontalInset,
                y: probabilityBottomY,
                width: bankedResetForecastMetricsWidth,
                height: forecastLineHeight
            )
            : nil
        let bankedResetDetailRows: [OpenCodexQuotaRowFrames] = {
            guard includesBankedReset, bankedDetailCount > 0 else { return [] }
            let iconSize = bankedResetTicketIconSize
            let chromeInset = bankedResetChromeInset
            let innerX = horizontalInset + chromeInset
            let innerRight = cardWidth - horizontalInset - chromeInset
            let textX = innerX + iconSize.width + bankedResetTicketIconGap
            let remainingX = innerRight - bankedResetRemainingWidth
            let titleWidth = max(64, remainingX - textX - 6)
            let lineWidth = max(64, innerRight - textX)
            let lineGap: CGFloat = 2
            return (0..<bankedDetailCount).map { index in
                // Unclipped 1–2 card lists stay in host coordinates so the
                // existing two-ticket menu still paints at bottomInset.
                // Clipped lists use document coordinates with y = 0 at the
                // last ticket; the scroll view sits at `bottomInset`.
                let originY: CGFloat = bankedTicketsNeedScroll ? 0 : bottomInset
                let y = originY
                    + CGFloat(bankedDetailCount - 1 - index) * (bankedDetailHeight + rowGap)
                let expiryY = y + chromeInset
                let windowY = expiryY + quotaResetHeight + lineGap
                let titleY = windowY + quotaResetHeight + lineGap
                let textBottom = expiryY
                let textTop = titleY + quotaDetailHeight
                let iconY = (textBottom + textTop - iconSize.height) / 2
                return OpenCodexQuotaRowFrames(
                    quotaDetail: CGRect(
                        x: textX,
                        y: titleY,
                        width: titleWidth,
                        height: quotaDetailHeight
                    ),
                    reset: CGRect(
                        x: textX,
                        y: expiryY,
                        width: lineWidth,
                        height: quotaResetHeight
                    ),
                    amount: CGRect(
                        x: remainingX,
                        y: y + (bankedDetailHeight - quotaDetailHeight) / 2,
                        width: bankedResetRemainingWidth,
                        height: quotaDetailHeight
                    ),
                    progress: .zero,
                    icon: CGRect(
                        x: innerX,
                        y: iconY,
                        width: iconSize.width,
                        height: iconSize.height
                    ),
                    window: CGRect(
                        x: textX,
                        y: windowY,
                        width: lineWidth,
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
            title: CGRect(x: horizontalInset, y: titleY, width: 189, height: 20),
            refreshTime: CGRect(x: refreshTimeX, y: titleY + 1, width: 81, height: 17),
            account: includesAccount
                ? CGRect(x: horizontalInset, y: baseTitleY, width: accountWidth, height: 17)
                : nil,
            subscription: hasSubscription
                ? CGRect(
                    x: subscriptionX,
                    y: baseTitleY,
                    width: subscriptionWidth,
                    height: 17
                )
                : nil,
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
                    y: bottomInset,
                    width: cardWidth,
                    height: bankedVisibleTicketStackHeight
                )
                : nil
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
