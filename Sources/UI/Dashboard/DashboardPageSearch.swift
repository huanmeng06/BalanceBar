import AppKit

/// Search hiding is tracked separately from business `isHidden`.
/// AppKit may echo `isHidden` while search is mutating layout; those writes
/// must not be stored as business visibility.
enum DashboardSearchVisibility {
    static var isMutatingSearchVisibility = false
    private static var businessKey: UInt8 = 0
    private static var searchKey: UInt8 = 0

    @discardableResult
    static func withSearchVisibilityMutation<T>(_ body: () throws -> T) rethrows -> T {
        let previous = isMutatingSearchVisibility
        isMutatingSearchVisibility = true
        defer { isMutatingSearchVisibility = previous }
        return try body()
    }

    static func writeHidden(_ view: NSView, _ hidden: Bool, superSetter: (Bool) -> Void) {
        if isMutatingSearchVisibility {
            superSetter(hidden)
            return
        }
        let wasBusinessHidden = isBusinessHidden(view)
        setBusinessHidden(view, hidden)
        superSetter(isEffectivelyHidden(view))
        if wasBusinessHidden != hidden {
            syncSeparatedRows(around: view)
            DashboardKeyViewLoop.invalidate(view.window)
        }
        if wasBusinessHidden, !hidden, !isEffectivelyHidden(view) {
            revealSearchHiddenSectionAncestors(of: view)
            hideSearchEmptyState(from: view)
            syncSeparatedRows(around: view)
            DashboardKeyViewLoop.invalidate(view.window)
        }
    }

    static func setBusinessHidden(_ view: NSView, _ hidden: Bool) {
        objc_setAssociatedObject(view, &businessKey, hidden, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func setSearchHidden(_ view: NSView, _ hidden: Bool) {
        objc_setAssociatedObject(view, &searchKey, hidden, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func isSearchHidden(_ view: NSView) -> Bool {
        objc_getAssociatedObject(view, &searchKey) as? Bool ?? false
    }

    static func isBusinessHidden(_ view: NSView) -> Bool {
        if let stored = objc_getAssociatedObject(view, &businessKey) as? Bool {
            return stored
        }
        return view.isHidden && !isSearchHidden(view)
    }

    static func isEffectivelyHidden(_ view: NSView) -> Bool {
        isBusinessHidden(view) || isSearchHidden(view)
    }

    static func restoreBusinessHidden(_ view: NSView) {
        let hidden = isBusinessHidden(view)
        withSearchVisibilityMutation {
            view.isHidden = hidden
        }
    }

    static func restoreCollapsedStackVisibility(_ view: NSView) {
        guard let stack = view.superview as? NSStackView,
              stack.arrangedSubviews.contains(view),
              stack.visibilityPriority(for: view) == .notVisible else {
            return
        }
        stack.setVisibilityPriority(.mustHold, for: view)
    }

    private static func revealSearchHiddenSectionAncestors(of view: NSView) {
        var current = view.superview
        while let ancestor = current {
            if isSearchableSection(ancestor), isSearchHidden(ancestor), !isBusinessHidden(ancestor) {
                setSearchHidden(ancestor, false)
                withSearchVisibilityMutation {
                    restoreCollapsedStackVisibility(ancestor)
                    ancestor.isHidden = false
                }
            }
            current = ancestor.superview
        }
    }

    private static func hideSearchEmptyState(from view: NSView) {
        var root: NSView = view
        while let parent = root.superview {
            root = parent
        }
        hideSearchEmptyState(in: root)
    }

    private static func hideSearchEmptyState(in view: NSView) {
        if view.identifier == DashboardPageSearch.emptyStateIdentifier {
            view.isHidden = true
            return
        }
        for child in view.subviews {
            hideSearchEmptyState(in: child)
        }
    }

    private static func syncSeparatedRows(around view: NSView) {
        guard let stack = view.superview as? NSStackView else { return }
        let arranged = stack.arrangedSubviews
        for (index, candidate) in arranged.enumerated() {
            guard candidate is NSBox else { continue }
            let previousVisible = arranged[..<index].reversed().first { !($0 is NSBox) }.map {
                !isCollapsedForSearchLayout($0)
            } ?? false
            let nextVisible = arranged[(index + 1)...].first { !($0 is NSBox) }.map {
                !isCollapsedForSearchLayout($0)
            } ?? false
            let shouldHide = !(previousVisible && nextVisible)
            if shouldHide {
                if !candidate.isHidden && !isSearchHidden(candidate) {
                    candidate.isHidden = true
                }
            } else {
                if isSearchHidden(candidate), !isBusinessHidden(candidate) {
                    setSearchHidden(candidate, false)
                    withSearchVisibilityMutation {
                        restoreCollapsedStackVisibility(candidate)
                    }
                }
                if !isBusinessHidden(candidate), candidate.isHidden {
                    withSearchVisibilityMutation {
                        candidate.isHidden = false
                    }
                }
            }
            DashboardSettingsComponents.invalidateHostedSettingsRowHeight(for: candidate)
        }
    }

    static func isCollapsedForSearchLayout(_ view: NSView) -> Bool {
        if isEffectivelyHidden(view) || view.isHidden {
            return true
        }
        if let stack = view.superview as? NSStackView,
           stack.arrangedSubviews.contains(view),
           stack.visibilityPriority(for: view) == .notVisible {
            return true
        }
        return false
    }

    private static func isSearchableSection(_ view: NSView) -> Bool {
        view is SettingsSectionView || view.identifier == DashboardPageSearch.sectionIdentifier
    }
}

/// Dashboard settings search: toolbar query interpretation, page filtering,
/// and cross-section jump catalog. Empty results reuse SettingsSectionView.
/// The catalog is a candidate list only; live pages re-check business visibility.
enum DashboardPageSearch {
    static let sectionIdentifier = NSUserInterfaceItemIdentifier("dashboard.settings.section")
    static let rowIdentifier = NSUserInterfaceItemIdentifier("dashboard.settings.row")
    static let emptyStateIdentifier = NSUserInterfaceItemIdentifier("dashboard.search.emptyState")
    static let aboutContentIdentifier = NSUserInterfaceItemIdentifier("dashboard.about.content")
    static let globalSearchGroupIdentifier = NSUserInterfaceItemIdentifier("dashboard.search.globalGroup")
    private static var searchableRowKey: UInt8 = 0
    private static let normalizedTextCache = NSCache<NSString, NSString>()
    private static let fuzzyWordsCache = NSCache<NSString, NSArray>()

    enum MatchKind: Int, Comparable, Sendable {
        case fuzzy = 1
        case alias = 2
        case keywords = 3
        case contains = 4
        case exact = 5

        static func < (lhs: MatchKind, rhs: MatchKind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Match: Equatable, Comparable, Sendable {
        let kind: MatchKind
        let relevance: Double

        init(kind: MatchKind, relevance: Double = 0) {
            self.kind = kind
            self.relevance = relevance
        }

        static func < (lhs: Match, rhs: Match) -> Bool {
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.relevance < rhs.relevance
        }
    }

    private struct WeightedText {
        let value: String
        let weight: Double
    }

    static func matches(_ text: String, query: String) -> Bool {
        bestMatch(texts: [text], query: query) != nil
    }

    static func bestMatch(
        texts: [String],
        aliases: [String] = [],
        supportingTexts: [String] = [],
        query: String
    ) -> Match? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let values = texts + supportingTexts
        guard values.contains(where: { $0.localizedStandardContains(needle) }) else {
            return nil
        }
        return Match(kind: .contains, relevance: 1)
    }

    static func normalize(_ text: String) -> String {
        if let cached = normalizedTextCache.object(forKey: text as NSString) {
            return cached as String
        }
        let widthFolded = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let folded = widthFolded.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let normalized = folded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        normalizedTextCache.setObject(normalized as NSString, forKey: text as NSString)
        return normalized
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func bestDirectMatch(
        values: [WeightedText],
        query: String,
        queryTokens: [String],
        kind: MatchKind?
    ) -> Match? {
        guard !values.isEmpty else { return nil }
        if let exact = values.filter({ $0.value == query }).max(by: { $0.weight < $1.weight }) {
            return Match(kind: kind ?? .exact, relevance: exact.weight * 1.25)
        }
        let compactQuery = query.filter { !$0.isWhitespace }
        if let contains = values.filter({ source in
            source.value.localizedStandardContains(query)
                || source.value.filter { !$0.isWhitespace }.localizedStandardContains(compactQuery)
        }).map({ source in
            let compactValue = source.value.filter { !$0.isWhitespace }
            let sequenceBonus = compactQuery.count >= 3
                ? min(0.35, contiguousChunkSimilarity(compactQuery, in: compactValue))
                : 0
            return source.weight * (
                1
                    + directPositionBonus(compactQuery, in: compactValue)
                    + sequenceBonus
            )
        }).max() {
            return Match(kind: kind ?? .contains, relevance: contains)
        }
        return nil
    }

    private static func directPositionBonus(_ query: String, in source: String) -> Double {
        guard let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return 0
        }
        let offset = source.distance(from: source.startIndex, to: range.lowerBound)
        let atWordBoundary = range.lowerBound == source.startIndex
            || !source[source.index(before: range.lowerBound)].isLetter
        return (atWordBoundary ? 0.12 : 0) + (offset == 0 ? 0.12 : 0)
    }

    /// PCL2's matcher scores ordered runs of consecutive characters and
    /// rewards longer runs. This small, bounded variant complements edit
    /// distance for compact or partially typed words without fuzzy-matching
    /// one- and two-character inputs.
    private static func contiguousChunkSimilarity(_ query: String, in source: String) -> Double {
        let needle = Array(query.filter { !$0.isWhitespace })
        var remaining = Array(source.filter { !$0.isWhitespace })
        guard needle.count >= 3, !remaining.isEmpty else { return 0 }
        let sourceLength = remaining.count
        var queryIndex = 0
        var total = 0.0

        while queryIndex < needle.count {
            var bestLength = 0
            var bestStart = 0
            for start in remaining.indices {
                var length = 0
                while queryIndex + length < needle.count,
                      start + length < remaining.count,
                      needle[queryIndex + length] == remaining[start + length] {
                    length += 1
                }
                if length > bestLength {
                    bestLength = length
                    bestStart = start
                }
            }
            guard bestLength > 0 else {
                queryIndex += 1
                continue
            }
            let runWeight = pow(1.4, Double(3 + bestLength)) - 3.6
            let positionBonus = 1 + 0.3 * Double(max(0, 3 - abs(queryIndex - bestStart)))
            total += runWeight * positionBonus
            remaining.removeSubrange(bestStart..<(bestStart + bestLength))
            queryIndex += bestLength
        }
        let shortQueryFactor = needle.count <= 2 ? Double(3 - needle.count) : 1
        return (total / Double(needle.count))
            * (3 / sqrt(Double(sourceLength + 15)))
            * shortQueryFactor
    }

    private static func fuzzyWords(in text: String) -> [String] {
        if let cached = fuzzyWordsCache.object(forKey: text as NSString) {
            return cached.compactMap { $0 as? String }
        }
        let words = text.split { (character: Character) in
            !(character.isLetter || character.isNumber)
        }.map(String.init).filter { $0.count >= 4 }
        fuzzyWordsCache.setObject(words as NSArray, forKey: text as NSString)
        return words
    }

    private static func fuzzyDistanceLimit(for token: String) -> Int {
        token.count >= 7 ? 2 : 1
    }

    /// Damerau-Levenshtein distance with one adjacent transposition. The
    /// minimum four-character token guard keeps short/random queries from
    /// turning into broad page matches.
    private static func fuzzyDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= maximum else { return maximum + 1 }
        var matrix = Array(repeating: Array(repeating: 0, count: right.count + 1), count: left.count + 1)
        for index in 0...left.count { matrix[index][0] = index }
        for index in 0...right.count { matrix[0][index] = index }
        guard !left.isEmpty, !right.isEmpty else { return max(left.count, right.count) }
        for i in 1...left.count {
            var rowMinimum = Int.max
            for j in 1...right.count {
                let substitution = left[i - 1] == right[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + substitution
                )
                if i > 1, j > 1,
                   left[i - 1] == right[j - 2], left[i - 2] == right[j - 1] {
                    matrix[i][j] = min(matrix[i][j], matrix[i - 2][j - 2] + 1)
                }
                rowMinimum = min(rowMinimum, matrix[i][j])
            }
            if rowMinimum > maximum { return maximum + 1 }
        }
        return matrix[left.count][right.count]
    }

    /// Marks a row as searchable without requiring `identifier` to stay
    /// `rowIdentifier`. Production rows may overwrite the factory identifier.
    static func markSearchableRow(_ view: NSView) {
        objc_setAssociatedObject(view, &searchableRowKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func isSearchableRow(_ view: NSView) -> Bool {
        if view is SettingsRowView {
            return true
        }
        if objc_getAssociatedObject(view, &searchableRowKey) as? Bool == true {
            return true
        }
        return view.identifier == rowIdentifier
    }

    static func matchDocuments(
        _ documents: [DashboardSearchDocument],
        query: String,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [DashboardSearchMatchResult] {
        var matches: [DashboardSearchMatchResult] = []
        matches.reserveCapacity(documents.count / 4)
        for document in documents {
            if isCancelled() { return [] }
            guard document.businessVisible,
                  let match = bestMatch(
                    texts: document.texts,
                    aliases: document.aliases,
                    supportingTexts: document.supportingTexts,
                    query: query
                  ) else {
                continue
            }
            matches.append(
                DashboardSearchMatchResult(documentID: document.id, match: match)
            )
        }
        return matches.sorted {
            if $0.match != $1.match { return $0.match > $1.match }
            return $0.documentID < $1.documentID
        }
    }
}

enum DashboardPageSearchMode: Sendable {
    /// Settings pages: section headings and row titles.
    case titles
    /// Provider detail and About: currently visible copy.
    case visibleCopy
}

/// Immutable search input prepared on the main thread and consumed by the
/// background matcher. It intentionally contains no AppKit objects.
struct DashboardSearchDocument: Sendable {
    let id: String
    let sectionID: String?
    let texts: [String]
    let aliases: [String]
    let supportingTexts: [String]
    let businessVisible: Bool
    let order: Int
}

struct DashboardSearchMatchResult: Sendable {
    let documentID: String
    let match: DashboardPageSearch.Match
}

enum DashboardSettingsSearchCatalog {
    private struct AliasDefinition {
        let canonical: [String]
        let aliases: [String]
    }

    private static let aliasDefinitions: [AliasDefinition] = [
        AliasDefinition(
            canonical: [
                tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin),
                "Launch at Login",
                "登录时自动启动"
            ],
            aliases: ["开机启动", "开机自启", "autostart", "startup"]
        ),
        AliasDefinition(
            canonical: [
                tr(.keyDashboardGeneralAndRefreshPagesLanguage),
                "Language",
                "语言"
            ],
            aliases: ["lang"]
        ),
        AliasDefinition(
            canonical: [
                tr(.keyDashboardMenuBarPageMenuBarFontSize),
                "Menu Bar Font Size",
                "菜单栏字号"
            ],
            aliases: ["menu font", "font size", "菜单栏字体", "字号"]
        )
    ]

    private static let localizedSearchCopy: [DashboardSection: [String]] = {
        let bundles = Bundle.main.localizations.compactMap { localization -> Bundle? in
            guard let path = Bundle.main.path(forResource: localization, ofType: "lproj") else {
                return nil
            }
            return Bundle(path: path)
        }
        let interpolationPattern = try? NSRegularExpression(
            pattern: "%([0-9]+\\$)?[-+0-9.#]*[a-zA-Z@]"
        )
        return Dictionary(uniqueKeysWithValues: DashboardSection.allCases.map { section in
            let prefix = localizationPrefix(for: section)
            var values: [String] = []
            for key in LocalizationKey.allCases where key.rawValue.hasPrefix(prefix) {
                for bundle in bundles {
                    let localized = bundle.localizedString(
                        forKey: key.rawValue,
                        value: "",
                        table: "Localizable"
                    )
                    guard !localized.isEmpty else { continue }
                    let range = NSRange(localized.startIndex..<localized.endIndex, in: localized)
                    let copy = interpolationPattern?.stringByReplacingMatches(
                        in: localized,
                        range: range,
                        withTemplate: " "
                    ) ?? localized
                    let trimmed = copy.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { values.append(trimmed) }
                }
            }
            return (section, Array(Set(values)))
        })
    }()

    static func aliases(for title: String) -> [String] {
        definition(for: title)?.aliases ?? []
    }

    /// Returns all localized and stable English names for a setting identity.
    /// The current UI title alone is insufficient when a user searches in a
    /// different language from the one used by the setting's canonical name.
    static func canonicalValues(for title: String) -> [String] {
        definition(for: title)?.canonical ?? []
    }

    private static func definition(for title: String) -> AliasDefinition? {
        let normalizedTitle = DashboardPageSearch.normalize(title)
        return aliasDefinitions.first {
            $0.canonical.contains { DashboardPageSearch.normalize($0) == normalizedTitle }
        }
    }

    static func titles(for section: DashboardSection) -> [String] {
        var values = [section.title]
        values.append(contentsOf: keys(for: section).map { tr($0) })
        values.append(contentsOf: extraTitles(for: section))
        return values
    }

    private static func localizationPrefix(for section: DashboardSection) -> String {
        switch section {
        case .general: return "dashboard.general.and.refresh.pages."
        case .menuBar: return "dashboard.menu.bar.page."
        case .menu: return "dashboard.menu.page."
        case .advanced: return "dashboard.advanced.page."
        case .about: return "dashboard.about.page."
        }
    }

    static func matchingSections(query: String) -> [DashboardSection] {
        rankedSections(query: query).map(\.section)
    }

    static func rankedSections(
        query: String,
        statusLinks: [StatusLink] = [],
        runtimeTexts: [DashboardSection: [String]] = [:],
        includeSupportingTexts: Bool = true,
        singleCharacterWordBoundaryOnly: Bool = false
    ) -> [(section: DashboardSection, match: DashboardPageSearch.Match)] {
        var scored: [(section: DashboardSection, match: DashboardPageSearch.Match)] = []
        for section in DashboardSection.allCases {
            let match = DashboardPageSearch.bestMatch(
                texts: titles(for: section),
                query: query
            )
            if let match {
                scored.append((section: section, match: match))
            }
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.match != rhs.match { return lhs.match > rhs.match }
                return lhs.section.rawValue < rhs.section.rawValue
            }
    }

    static func match(
        for section: DashboardSection,
        query: String,
        includeSupportingTexts: Bool = true,
        singleCharacterWordBoundaryOnly: Bool = false
    ) -> DashboardPageSearch.Match? {
        return DashboardPageSearch.bestMatch(
            texts: titles(for: section),
            query: query
        )
    }

    private static func containsSingleCharacterWordBoundary(
        _ text: String,
        query: String
    ) -> Bool {
        let normalizedText = DashboardPageSearch.normalize(text)
        let normalizedQuery = DashboardPageSearch.normalize(query)
        guard normalizedQuery.count == 1,
              let queryCharacter = normalizedQuery.first else {
            return false
        }
        return normalizedText.split(whereSeparator: { $0.isWhitespace }).contains {
            $0.first == queryCharacter
        }
    }

    static func firstMatchingSection(query: String) -> DashboardSection? {
        matchingSections(query: query).first
    }

    static func keys(for section: DashboardSection) -> [LocalizationKey] {
        switch section {
        case .general:
            return [
                .keyDashboardGeneralAndRefreshPagesSystem,
                .keyDashboardGeneralAndRefreshPagesCcSwitch,
                .keyDashboardGeneralAndRefreshPagesLaunchAtLogin,
                .keyDashboardGeneralAndRefreshPagesSilentLaunch,
                .keyDashboardGeneralAndRefreshPagesLaunchWithChatGPT,
                .keyDashboardGeneralAndRefreshPagesStartup,
                .keyDashboardGeneralAndRefreshPagesRefresh,
                .keyDashboardGeneralAndRefreshPagesBalanceUpdatesDuringTasks,
                .keyDashboardGeneralAndRefreshPagesBalanceData,
                .keyDashboardGeneralAndRefreshPagesApplication,
                .keyDashboardGeneralAndRefreshPagesLanguage,
                .keyDashboardGeneralAndRefreshPagesUpdateChannel,
                .keyDashboardGeneralAndRefreshPagesCheckForUpdates3
            ]
        case .menuBar:
            return [
                .keyDashboardMenuBarPagePreview,
                .keyDashboardMenuBarPageCurrentLayout,
                .keyDashboardMenuBarPageIconDisplayMode,
                .keyDashboardMenuBarPageIconDisplayDelay,
                .keyDashboardMenuBarPageQuotaAndReset,
                .keyDashboardMenuBarPageQuotaDisplayPriority,
                .keyDashboardMenuBarPageBalanceAmount,
                .keyDashboardMenuBarPageResetCountdown,
                .keyDashboardMenuBarPageQuotaResetDisplayMode,
                .keyDashboardMenuBarPageIconAndTaskStatus,
                .keyDashboardMenuBarPageAgentIcon,
                .keyDashboardMenuBarPagePlayTheIconAnimationWhileATaskIsRunning,
                .keyDashboardMenuBarPageAnimation,
                .keyDashboardMenuBarPageAnimationFrameRate,
                .keyDashboardMenuBarPageBehavior,
                .keyDashboardMenuBarPageRightClick,
                .keyDashboardMenuBarPageReverseMouseButtons,
                .keyDashboardMenuBarPageLayout,
                .keyDashboardMenuBarPageMenuBarFontSize,
                .keyDashboardMenuBarPageMenuBarIconSize,
                .keyDashboardMenuBarPageIconOffset,
                .keyDashboardMenuBarPageAmountOffset,
                .keyDashboardMenuBarPageMenuBarWidth
            ]
        case .menu:
            return [
                .keyDashboardMenuPageBalanceDisplay,
                .keyDashboardMenuPageShowBankedReset,
                .keyDashboardMenuPageBankedResetDisplayMode,
                .keyCodexBankedResetTitle,
                .keyDashboardMenuPageShowQuotaProgressBar,
                .keyDashboardMenuPageProgressColorRanges,
                .keyDashboardMenuPageDisplayedColors,
                .keyDashboardMenuPageLowBalanceDisplayThreshold,
                .keyDashboardMenuPageProgressBar,
                .keyDashboardMenuPageMenuBehavior,
                .keyDashboardMenuPageQuickSwitch,
                .keyDashboardMenuPageKeepOpenAfterRefresh,
                .keyDashboardMenuPageOpenProject,
                .keyDashboardMenuPageOpenMainWindow,
                .keyDashboardMenuPageOpenChatgpt,
                .keyDashboardMenuPageOpenCcSwitch,
                .keyDashboardMenuPageStatusLinks,
                .keyDashboardMenuPageViewStatus
            ]
        case .advanced:
            return [
                .keyDashboardAdvancedPageDiagnostics,
                .keyDashboardAdvancedPageDebugLog
            ]
        case .about:
            return [
                .keyDashboardAboutPageGithubRepository,
                .keyDashboardAboutPageACcSwitchBasedMenuBarBalanceViewer,
                .keyDashboardAboutPageOpenTheBalancebarGithubRepository
            ]
        }
    }

    private static func extraTitles(for section: DashboardSection) -> [String] {
        switch section {
        case .menuBar:
            return [
                tr(.keyDashboardMenuBarPageQuotaDisplayPriorityDescription),
                tr(.keyDashboardMenuBarPageFiveHourQuota),
                tr(.keyDashboardMenuBarPageSevenDayQuota),
                tr(
                    .keyDashboardMenuBarPageAutoSwitchLunaReserve,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                tr(
                    .keyDashboardMenuBarPageLunaReserveResetTime,
                    arguments: [tr(.keyLunaReserveTitle)]
                )
            ]
        case .about:
            return [
                "BalanceBar",
                tr(.keyDashboardAboutPageVersionValue, arguments: [""])
            ]
        case .general, .menu, .advanced:
            if section == .menu {
                return [
                    tr(.keyDashboardMenuPageLunaReserveDisplayMode, arguments: [tr(.keyLunaReserveTitle)]),
                    tr(.keyDashboardMenuPageHideExhaustedQuota)
                ]
            }
            return []
        }
    }
}

/// Deterministic counters used by search regression tests. They describe
/// structural work, rather than timing, so CI can enforce the steady-state
/// query contract without relying on a machine-specific performance budget.
enum DashboardPageSearchDiagnostics {
    static var searchIndexBuildCount = 0
    static var synchronousLayoutCount = 0
    static var globalSearchPagesMaterializedCount = 0

    static func reset() {
        searchIndexBuildCount = 0
        synchronousLayoutCount = 0
        globalSearchPagesMaterializedCount = 0
    }
}

final class DashboardPageSearchFilter {
    var statusLinks: [StatusLink] = []
    private final class SearchIndex {
        weak var root: NSView?
        let sections: [NSView]
        let rowsBySection: [ObjectIdentifier: [NSView]]
        let globalSearchGroups: [NSView]
        let documents: [DashboardSearchDocument]
        let documentIDByView: [ObjectIdentifier: String]
        let topLevelDocumentIDs: [String]
        let visibleCopyByView: [ObjectIdentifier: [String]]
        let topLevelVisibleCopy: [String]

        init(
            root: NSView,
            sections: [NSView],
            rowsBySection: [ObjectIdentifier: [NSView]],
            globalSearchGroups: [NSView],
            documents: [DashboardSearchDocument],
            documentIDByView: [ObjectIdentifier: String],
            topLevelDocumentIDs: [String],
            visibleCopyByView: [ObjectIdentifier: [String]],
            topLevelVisibleCopy: [String]
        ) {
            self.root = root
            self.sections = sections
            self.rowsBySection = rowsBySection
            self.globalSearchGroups = globalSearchGroups
            self.documents = documents
            self.documentIDByView = documentIDByView
            self.topLevelDocumentIDs = topLevelDocumentIDs
            self.visibleCopyByView = visibleCopyByView
            self.topLevelVisibleCopy = topLevelVisibleCopy
        }
    }

    private let searchIndexes = NSMapTable<NSView, SearchIndex>.strongToStrongObjects()
    private var activeSearchIndex: SearchIndex?
    private var activeDocumentMatches: Set<String>?
    private var needsInitialProjectionLayout = true
    private let hiddenBySearch = NSHashTable<NSView>.weakObjects()
    private let originalStackVisibilityPriority = NSMapTable<NSView, NSNumber>.weakToStrongObjects()
    private let originalStackParent = NSMapTable<NSView, NSStackView>.strongToWeakObjects()
    private let originalStackIndex = NSMapTable<NSView, NSNumber>.weakToStrongObjects()
    private let originalStackWidthConstraint = NSMapTable<NSView, NSLayoutConstraint>.strongToStrongObjects()

    func invalidateSearchIndex() {
        searchIndexes.removeAllObjects()
        activeSearchIndex = nil
        activeDocumentMatches = nil
    }

    func resetSearchState() {
        restoreSearchHiddens()
        invalidateSearchIndex()
        activeDocumentMatches = nil
    }

    func requestVisibilityReset() {
        invalidateSearchIndex()
    }

    func prepareForDataRefresh() {
        restoreSearchHiddens()
        invalidateSearchIndex()
    }

    func markSearchStructureChanged() {
        restoreSearchHiddens()
        invalidateSearchIndex()
        needsInitialProjectionLayout = true
    }

    func searchDocuments(for root: NSView) -> [DashboardSearchDocument] {
        index(for: root).documents
    }

    @discardableResult
    func apply(
        query: String,
        to root: NSView,
        pageTitle: String,
        mode: DashboardPageSearchMode,
        matchedDocumentIDs: Set<String>? = nil
    ) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageTitleMatches = !needle.isEmpty
            && DashboardPageSearch.matches(pageTitle, query: needle)
        if needle.isEmpty || pageTitleMatches {
            restoreSearchHiddens()
        }
        let searchIndex = index(for: root)
        activeSearchIndex = searchIndex
        activeDocumentMatches = matchedDocumentIDs
        defer {
            activeSearchIndex = nil
            activeDocumentMatches = nil
        }
        // Search-hidden rows remain in the index even when NSStackView has
        // detached them. Filtering can therefore restore or collapse only
        // the result-set delta instead of rebuilding the whole projection.
        if needle.isEmpty {
            setEmptyStateHidden(true, in: root)
            restoreAboutContent(in: root)
            refreshSearchSectionHeights(in: root)
            return true
        }
        if pageTitleMatches {
            setEmptyStateHidden(true, in: root)
            restoreAboutContent(in: root)
            refreshSearchSectionHeights(in: root)
            return true
        }

        let matched: Bool
        switch mode {
        case .titles:
            matched = applyTitleFilter(query: needle, to: root)
        case .visibleCopy:
            matched = applyVisibleCopyFilter(query: needle, to: root)
        }
        synchronizeGlobalSearchGroups(in: root)
        setEmptyStateHidden(matched, in: root)
        if !matched {
            hideAboutContentIfPresent(in: root)
        } else {
            restoreAboutContent(in: root)
            revealFirstMatch(in: root)
        }
        root.needsLayout = true
        refreshSearchSectionHeights(in: root)
        return matched
    }

    private func synchronizeGlobalSearchGroups(in root: NSView) {
        for group in globalSearchGroups(in: root) {
            let hasVisibleSection = containsVisibleSearchSection(in: group)
            if hasVisibleSection {
                _ = restoreSearchHiddenView(group)
            } else {
                hideForSearch(group)
            }
        }
    }

    private func globalSearchGroups(in view: NSView) -> [NSView] {
        if let activeSearchIndex, activeSearchIndex.root === view {
            return activeSearchIndex.globalSearchGroups
        }
        var result: [NSView] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ candidate: NSView) {
            let identity = ObjectIdentifier(candidate)
            guard visited.insert(identity).inserted else { return }
            if candidate.identifier == DashboardPageSearch.globalSearchGroupIdentifier {
                result.append(candidate)
            }
            for child in candidate.subviews {
                visit(child)
            }
            if let stack = candidate as? NSStackView {
                for arranged in stack.arrangedSubviews {
                    visit(arranged)
                }
            }
        }
        visit(view)
        return result
    }

    private func containsVisibleSearchSection(in view: NSView) -> Bool {
        if let section = view as? SettingsSectionView {
            return !DashboardSearchVisibility.isEffectivelyHidden(section)
                && !DashboardSearchVisibility.isBusinessHidden(section)
        }
        var descendants = view.subviews
        if let stack = view as? NSStackView {
            descendants.append(contentsOf: stack.arrangedSubviews)
        }
        return descendants.contains { containsVisibleSearchSection(in: $0) }
    }

    private func refreshSearchSectionHeights(in root: NSView) {
        if globalSearchGroups(in: root).isEmpty {
            for section in collectSections(in: root) {
                (section as? SettingsSectionView)?
                    .updateSearchNaturalHeightConstraintForCurrentVisibility()
            }
        }
        root.needsLayout = true
        if needsInitialProjectionLayout {
            DashboardPageSearchDiagnostics.synchronousLayoutCount += 1
            root.layoutSubtreeIfNeeded()
            needsInitialProjectionLayout = false
        }
    }

    func pageContainsMatch(
        query: String,
        in root: NSView,
        pageTitle: String,
        mode: DashboardPageSearchMode
    ) -> Bool {
        pageMatch(query: query, in: root, pageTitle: pageTitle, mode: mode) != nil
    }

    func pageMatch(
        query: String,
        in root: NSView,
        pageTitle: String,
        mode: DashboardPageSearchMode
    ) -> DashboardPageSearch.Match? {
        let searchIndex = index(for: root)
        activeSearchIndex = searchIndex
        defer { activeSearchIndex = nil }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        var best = DashboardPageSearch.bestMatch(texts: [pageTitle], query: needle)
        func keepBest(_ candidate: DashboardPageSearch.Match?) {
            guard let candidate else { return }
            if best == nil || candidate > best! { best = candidate }
        }
        switch mode {
        case .titles:
            for section in collectSections(in: root) {
                if let heading = sectionHeading(section) {
                    keepBest(DashboardPageSearch.bestMatch(texts: [heading], query: needle))
                }
                for row in rows(in: section) {
                    keepBest(rowMatch(row, query: needle, includeVisibleCopy: true, sectionHeading: sectionHeading(section)))
                }
            }
        case .visibleCopy:
            let sections = collectSections(in: root)
            for section in sections {
                if let heading = sectionHeading(section) {
                    keepBest(DashboardPageSearch.bestMatch(texts: [heading], query: needle))
                }
                for row in rows(in: section) {
                    keepBest(rowMatch(row, query: needle, includeVisibleCopy: true, sectionHeading: sectionHeading(section)))
                }
            }
            for copy in visibleCopy(in: root, skipping: sections) {
                keepBest(DashboardPageSearch.bestMatch(texts: [copy], query: needle))
            }
        }
        return best
    }

    private func applyTitleFilter(query: String, to root: NSView) -> Bool {
        let sections = collectSections(in: root)
        guard !sections.isEmpty else {
            return applyVisibleCopyFilter(query: query, to: root)
        }
        var anyMatch = false
        for section in sections {
            let result = applySectionFilter(section, query: query, includeVisibleCopy: false)
            if result.countsAsHit {
                _ = restoreSearchHiddenView(section)
                anyMatch = true
            } else if result.hideSectionForSearch {
                hideForSearch(section)
            }
        }
        return anyMatch
    }

    private func applyVisibleCopyFilter(query: String, to root: NSView) -> Bool {
        let sections = collectSections(in: root)
        if sections.isEmpty {
            let matched: Bool
            if let activeDocumentMatches,
               let index = activeSearchIndex {
                matched = index.topLevelDocumentIDs.contains {
                    activeDocumentMatches.contains($0)
                }
            } else {
                matched = (activeSearchIndex?.topLevelVisibleCopy ?? visibleCopy(in: root)).contains {
                    DashboardPageSearch.matches($0, query: query)
                }
            }
            if !matched {
                hideAboutContentIfPresent(in: root)
            }
            return matched
        }
        var anyMatch = false
        for section in sections {
            let result = applySectionFilter(section, query: query, includeVisibleCopy: true)
            if result.countsAsHit {
                _ = restoreSearchHiddenView(section)
                anyMatch = true
            } else if result.hideSectionForSearch {
                hideForSearch(section)
            }
        }
        var topLevelCopy = activeSearchIndex?.topLevelVisibleCopy
            ?? visibleCopy(in: root, skipping: sections)
        if !statusLinks.isEmpty, containsStatusLinksEditor(in: root) {
            topLevelCopy.append(contentsOf: statusLinks.flatMap { [$0.title, $0.url] })
        }
        let unmatchedTopLevel: Bool
        if let activeDocumentMatches,
           let index = activeSearchIndex {
            unmatchedTopLevel = index.topLevelDocumentIDs.contains {
                activeDocumentMatches.contains($0)
            }
        } else {
            unmatchedTopLevel = topLevelCopy.contains {
                DashboardPageSearch.matches($0, query: query)
            }
        }
        return anyMatch || unmatchedTopLevel
    }

    private struct SectionFilterResult {
        var countsAsHit: Bool
        var hideSectionForSearch: Bool
    }

    private func applySectionFilter(
        _ section: NSView,
        query: String,
        includeVisibleCopy: Bool = false
    ) -> SectionFilterResult {
        let headingMatches: Bool
        if let activeDocumentMatches,
           let sectionID = activeSearchIndex?.documentIDByView[ObjectIdentifier(section)] {
            headingMatches = activeDocumentMatches.contains(sectionID)
        } else {
            headingMatches = sectionHeading(section).map {
                DashboardPageSearch.bestMatch(texts: [$0], query: query) != nil
            } == true
        }
        if headingMatches {
            _ = restoreSearchHiddenView(section)
            for row in rows(in: section) {
                _ = restoreSearchHiddenView(row)
            }
            return SectionFilterResult(
                countsAsHit: !DashboardSearchVisibility.isBusinessHidden(section),
                hideSectionForSearch: false
            )
        }
        guard let stack = rowStack(in: section) else {
            var searchableCopy = includeVisibleCopy ? visibleCopy(in: section) : []
            if includeVisibleCopy, containsStatusLinksEditor(in: section) {
                searchableCopy.append(contentsOf: statusLinks.flatMap { [$0.title, $0.url] })
            }
            let visibleCopyMatches = searchableCopy.contains {
                DashboardPageSearch.matches($0, query: query)
            }
            let countsAsHit = visibleCopyMatches && !DashboardSearchVisibility.isBusinessHidden(section)
            return SectionFilterResult(
                countsAsHit: countsAsHit,
                hideSectionForSearch: !countsAsHit
            )
        }
        var visibleRowCount = 0
        let heading = sectionHeading(section)
        for view in rows(in: section) where !(view is NSBox) {
            if rowContentMatches(
                view,
                query: query,
                includeVisibleCopy: includeVisibleCopy,
                sectionHeading: heading
            ) {
                _ = restoreSearchHiddenView(view)
                if !DashboardSearchVisibility.isBusinessHidden(view) {
                    visibleRowCount += 1
                }
            } else {
                hideForSearch(view)
            }
        }
        syncSeparators(in: stack)
        return SectionFilterResult(
            countsAsHit: visibleRowCount > 0,
            hideSectionForSearch: visibleRowCount == 0
        )
    }

    private func sectionMatches(_ section: NSView, query: String) -> Bool {
        if sectionHeading(section).map({ DashboardPageSearch.bestMatch(texts: [$0], query: query) != nil }) == true {
            return true
        }
        return rows(in: section).contains {
            rowMatches(
                $0,
                query: query,
                includeVisibleCopy: true,
                sectionHeading: sectionHeading(section)
            )
        }
    }

    private func rowMatches(
        _ row: NSView,
        query: String,
        includeVisibleCopy: Bool,
        sectionHeading: String?
    ) -> Bool {
        rowMatch(
            row,
            query: query,
            includeVisibleCopy: includeVisibleCopy,
            sectionHeading: sectionHeading
        ) != nil
    }

    private func rowMatch(
        _ row: NSView,
        query: String,
        includeVisibleCopy: Bool,
        sectionHeading: String?
    ) -> DashboardPageSearch.Match? {
        guard !DashboardSearchVisibility.isBusinessHidden(row) else { return nil }
        return rowSearchMatch(
            row,
            query: query,
            includeVisibleCopy: includeVisibleCopy,
            sectionHeading: sectionHeading
        )
    }

    private func rowSearchMatch(
        _ row: NSView,
        query: String,
        includeVisibleCopy: Bool,
        sectionHeading: String?
    ) -> DashboardPageSearch.Match? {
        let title = rowTitle(of: row)
        var supportingValues: [String] = []
        if includeVisibleCopy {
            supportingValues.append(contentsOf: activeSearchIndex?.visibleCopyByView[ObjectIdentifier(row)]
                ?? visibleCopy(in: row))
        }
        return DashboardPageSearch.bestMatch(
            texts: [title],
            supportingTexts: supportingValues,
            query: query
        )
    }

    private func containsStatusLinksEditor(in view: NSView) -> Bool {
        if view is StatusLinksEditorHostingView { return true }
        return view.subviews.contains { containsStatusLinksEditor(in: $0) }
    }

    private func rowContentMatches(
        _ row: NSView,
        query: String,
        includeVisibleCopy: Bool,
        sectionHeading: String?
    ) -> Bool {
        if let activeDocumentMatches,
           let documentID = activeSearchIndex?.documentIDByView[ObjectIdentifier(row)] {
            return activeDocumentMatches.contains(documentID)
        }
        return rowSearchMatch(
            row,
            query: query,
            includeVisibleCopy: includeVisibleCopy,
            sectionHeading: sectionHeading
        ) != nil
    }

    private func collectSections(in view: NSView) -> [NSView] {
        if let activeSearchIndex, activeSearchIndex.root === view {
            return activeSearchIndex.sections
        }
        return collectSectionsUncached(in: view)
    }

    private func collectSectionsUncached(in view: NSView) -> [NSView] {
        if view.identifier == DashboardPageSearch.emptyStateIdentifier {
            return []
        }
        if view is SettingsSectionView || view.identifier == DashboardPageSearch.sectionIdentifier {
            return [view]
        }
        if DashboardSearchVisibility.isBusinessHidden(view) {
            return []
        }
        return view.subviews.flatMap { collectSectionsUncached(in: $0) }
    }

    private func index(for root: NSView) -> SearchIndex {
        if let existing = searchIndexes.object(forKey: root), existing.root === root {
            return existing
        }
        let sections = collectSectionsUncached(in: root)
        DashboardPageSearchDiagnostics.searchIndexBuildCount += 1
        var rowsBySection: [ObjectIdentifier: [NSView]] = [:]
        var documents: [DashboardSearchDocument] = []
        var documentIDByView: [ObjectIdentifier: String] = [:]
        var visibleCopyByView: [ObjectIdentifier: [String]] = [:]
        var documentOrder = 0
        for section in sections {
            let rows = rowsUncached(in: section)
            rowsBySection[ObjectIdentifier(section)] = rows
            let sectionID = searchDocumentID(for: section, prefix: "section")
            documentIDByView[ObjectIdentifier(section)] = sectionID
            if let heading = sectionHeading(section), !heading.isEmpty {
                documents.append(
                    DashboardSearchDocument(
                        id: sectionID,
                        sectionID: nil,
                        texts: [heading],
                        aliases: [],
                        supportingTexts: [],
                        businessVisible: !DashboardSearchVisibility.isBusinessHidden(section),
                        order: documentOrder
                    )
                )
                documentOrder += 1
            }
            for row in rows {
                let copy = visibleCopy(in: row)
                visibleCopyByView[ObjectIdentifier(row)] = copy
                let rowID = searchDocumentID(for: row, prefix: "row")
                documentIDByView[ObjectIdentifier(row)] = rowID
                let title = rowTitle(of: row)
                documents.append(
                    DashboardSearchDocument(
                        id: rowID,
                        sectionID: sectionID,
                        texts: [title],
                        aliases: [],
                        supportingTexts: ([sectionHeading(section)].compactMap { $0 } + copy),
                        businessVisible: !DashboardSearchVisibility.isBusinessHidden(row),
                        order: documentOrder
                    )
                )
                documentOrder += 1
            }
        }
        let globalSearchGroups = globalSearchGroupsUncached(in: root)
        let topLevelVisibleCopy = visibleCopy(in: root, skipping: sections)
        var topLevelDocumentIDs: [String] = []
        for copy in topLevelVisibleCopy {
            let id = "copy-\(documentOrder)"
            topLevelDocumentIDs.append(id)
            documents.append(
                DashboardSearchDocument(
                    id: id,
                    sectionID: nil,
                    texts: [copy],
                    aliases: [],
                    supportingTexts: [],
                    businessVisible: true,
                    order: documentOrder
                )
            )
            documentOrder += 1
        }
        let index = SearchIndex(
            root: root,
            sections: sections,
            rowsBySection: rowsBySection,
            globalSearchGroups: globalSearchGroups,
            documents: documents,
            documentIDByView: documentIDByView,
            topLevelDocumentIDs: topLevelDocumentIDs,
            visibleCopyByView: visibleCopyByView,
            topLevelVisibleCopy: topLevelVisibleCopy
        )
        searchIndexes.setObject(index, forKey: root)
        return index
    }

    private func searchDocumentID(for view: NSView, prefix: String) -> String {
        "\(prefix)-\(ObjectIdentifier(view).hashValue)"
    }

    private func rows(in section: NSView) -> [NSView] {
        if let activeSearchIndex,
           let rows = activeSearchIndex.rowsBySection[ObjectIdentifier(section)] {
            return rows
        }
        return rowsUncached(in: section)
    }

    private func rowsUncached(in section: NSView) -> [NSView] {
        if let native = section as? SettingsSectionView {
            return native.contentViews
        }
        return rowStack(in: section)?.arrangedSubviews.filter { !($0 is NSBox) } ?? []
    }

    private func globalSearchGroupsUncached(in view: NSView) -> [NSView] {
        var result: [NSView] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ candidate: NSView) {
            let identity = ObjectIdentifier(candidate)
            guard visited.insert(identity).inserted else { return }
            if candidate.identifier == DashboardPageSearch.globalSearchGroupIdentifier {
                result.append(candidate)
            }
            for child in candidate.subviews {
                visit(child)
            }
            if let stack = candidate as? NSStackView {
                for arranged in stack.arrangedSubviews {
                    visit(arranged)
                }
            }
        }
        visit(view)
        return result
    }

    private func rowStack(in section: NSView) -> NSStackView? {
        if let native = section as? SettingsSectionView {
            return native.cardView
        }
        if let stack = section as? NSStackView {
            return stack.arrangedSubviews.compactMap { candidate -> NSStackView? in
                if let nested = candidate as? NSStackView, nested.arrangedSubviews.contains(where: {
                    DashboardPageSearch.isSearchableRow($0)
                }) {
                    return nested
                }
                return candidate.subviews.compactMap { $0 as? NSStackView }.first
            }.first
        }
        return section.subviews.compactMap { $0 as? NSStackView }.first
    }

    private func sectionHeading(_ section: NSView) -> String? {
        if let native = section as? SettingsSectionView {
            let title = native.headingLabel.stringValue
            return title.isEmpty ? nil : title
        }
        if let stack = section as? NSStackView,
           let heading = stack.arrangedSubviews.first as? NSTextField {
            let title = heading.stringValue
            return title.isEmpty ? nil : title
        }
        return (section.subviews.first as? NSTextField).flatMap {
            $0.stringValue.isEmpty ? nil : $0.stringValue
        }
    }

    private func rowTitle(of view: NSView) -> String {
        if let row = view as? SettingsRowView {
            return row.titleLabel.stringValue
        }
        return firstTitleField(in: view)?.stringValue ?? ""
    }

    private func firstTitleField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, abs((field.font?.pointSize ?? 0) - 14) < 0.1 {
            return field
        }
        for child in view.subviews {
            if let found = firstTitleField(in: child) {
                return found
            }
        }
        return nil
    }

    private func visibleCopy(in view: NSView, skipping skip: [NSView] = []) -> [String] {
        if skip.contains(where: { view === $0 || view.isDescendant(of: $0) }) {
            return []
        }
        if view.identifier == DashboardPageSearch.emptyStateIdentifier {
            return []
        }
        if DashboardSearchVisibility.isBusinessHidden(view) {
            return []
        }
        if isHiddenSubtree(view) {
            return []
        }
        var values: [String] = []
        if let field = view as? NSTextField {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                values.append(text)
            }
        }
        if let button = view as? NSButton {
            let title = button.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                values.append(title)
            }
            if let label = button.accessibilityLabel(), !label.isEmpty {
                values.append(label)
            }
        }
        if let popup = view as? NSPopUpButton {
            values.append(contentsOf: popup.itemTitles)
        }
        for child in view.subviews {
            values.append(contentsOf: visibleCopy(in: child, skipping: skip))
        }
        return values
    }

    private func isHiddenSubtree(_ view: NSView) -> Bool {
        view.isHidden && !DashboardSearchVisibility.isSearchHidden(view)
    }

    private func syncSeparators(in stack: NSStackView) {
        let arranged = stack.arrangedSubviews
        for (index, view) in arranged.enumerated() {
            guard view is NSBox else { continue }
            let previousVisible = arranged[..<index].reversed().first { !($0 is NSBox) }.map {
                !DashboardSearchVisibility.isCollapsedForSearchLayout($0)
            } ?? false
            let nextVisible = arranged[(index + 1)...].first { !($0 is NSBox) }.map {
                !DashboardSearchVisibility.isCollapsedForSearchLayout($0)
            } ?? false
            let shouldShow = previousVisible && nextVisible
            if shouldShow {
                if DashboardSearchVisibility.isSearchHidden(view) {
                    _ = restoreSearchHiddenView(view)
                } else {
                    DashboardSearchVisibility.setBusinessHidden(view, view.isHidden)
                }
                if !DashboardSearchVisibility.isBusinessHidden(view) {
                    DashboardSearchVisibility.withSearchVisibilityMutation {
                        view.isHidden = false
                    }
                }
            } else {
                hideForSearch(view)
            }
        }
    }

    private func hideForSearch(_ view: NSView) {
        guard !DashboardSearchVisibility.isSearchHidden(view) else { return }
        DashboardSearchVisibility.setBusinessHidden(
            view,
            DashboardSearchVisibility.isBusinessHidden(view)
        )
        DashboardSearchVisibility.setSearchHidden(view, true)
        hiddenBySearch.add(view)
        guard !DashboardSearchVisibility.isBusinessHidden(view) else { return }
        collapseViewForSearch(view)
    }

    private func collapseViewForSearch(_ view: NSView) {
        var ownerStack: NSStackView?
        DashboardSearchVisibility.withSearchVisibilityMutation {
            if let stack = view.superview as? NSStackView, stack.arrangedSubviews.contains(view) {
                ownerStack = stack
                originalStackParent.setObject(stack, forKey: view)
                if let index = stack.arrangedSubviews.firstIndex(where: { $0 === view }) {
                    originalStackIndex.setObject(NSNumber(value: index), forKey: view)
                }
                if let widthConstraint = fullWidthConstraint(for: view, in: stack) {
                    originalStackWidthConstraint.setObject(widthConstraint, forKey: view)
                } else if shouldPreserveFullWidth(for: view, in: stack) {
                    let widthConstraint = view.widthAnchor.constraint(equalTo: stack.widthAnchor)
                    widthConstraint.isActive = true
                    originalStackWidthConstraint.setObject(widthConstraint, forKey: view)
                }
                if originalStackVisibilityPriority.object(forKey: view) == nil {
                    originalStackVisibilityPriority.setObject(
                        NSNumber(value: stack.visibilityPriority(for: view).rawValue),
                        forKey: view
                    )
                }
                stack.setVisibilityPriority(.notVisible, for: view)
            } else {
                view.isHidden = true
            }
        }
        DashboardSettingsComponents.invalidateHostedSettingsRowHeight(for: ownerStack ?? view)
    }

    @discardableResult
    private func restoreSearchHiddenView(_ view: NSView) -> NSStackView? {
        guard DashboardSearchVisibility.isSearchHidden(view) else { return nil }
        DashboardSearchVisibility.setSearchHidden(view, false)
        var restoredStack: NSStackView?
        DashboardSearchVisibility.withSearchVisibilityMutation {
            let stack: NSStackView? = {
                if let current = view.superview as? NSStackView,
                   current.arrangedSubviews.contains(view) {
                    return current
                }
                guard let original = originalStackParent.object(forKey: view) else { return nil }
                let index = originalStackIndex.object(forKey: view)?.intValue ?? original.arrangedSubviews.count
                original.insertArrangedSubview(view, at: min(index, original.arrangedSubviews.count))
                return original
            }()
            if let stack,
               let stored = originalStackVisibilityPriority.object(forKey: view) {
                originalStackWidthConstraint.object(forKey: view)?.isActive = true
                stack.setVisibilityPriority(
                    NSStackView.VisibilityPriority(rawValue: stored.floatValue),
                    for: view
                )
                restoredStack = stack
            }
        }
        originalStackVisibilityPriority.removeObject(forKey: view)
        originalStackParent.removeObject(forKey: view)
        originalStackIndex.removeObject(forKey: view)
        originalStackWidthConstraint.removeObject(forKey: view)
        hiddenBySearch.remove(view)
        DashboardSearchVisibility.restoreBusinessHidden(view)
        DashboardSettingsComponents.invalidateHostedSettingsRowHeight(for: restoredStack ?? view)
        return restoredStack
    }

    private func restoreSearchHiddens() {
        let stacks = NSHashTable<NSStackView>.weakObjects()
        for view in hiddenBySearch.allObjects {
            if let stack = restoreSearchHiddenView(view) {
                stacks.add(stack)
            }
        }
        hiddenBySearch.removeAllObjects()
        originalStackVisibilityPriority.removeAllObjects()
        originalStackParent.removeAllObjects()
        originalStackIndex.removeAllObjects()
        originalStackWidthConstraint.removeAllObjects()
        for stack in stacks.allObjects {
            syncSeparatorsAfterRestore(in: stack)
        }
    }

    private func syncSeparatorsAfterRestore(in stack: NSStackView) {
        let arranged = stack.arrangedSubviews
        for (index, view) in arranged.enumerated() {
            guard view is NSBox else { continue }
            let previousVisible = arranged[..<index].reversed().first { !($0 is NSBox) }.map {
                !DashboardSearchVisibility.isBusinessHidden($0)
            } ?? false
            let nextVisible = arranged[(index + 1)...].first { !($0 is NSBox) }.map {
                !DashboardSearchVisibility.isBusinessHidden($0)
            } ?? false
            let shouldShow = previousVisible && nextVisible
            DashboardSearchVisibility.setBusinessHidden(view, !shouldShow)
            DashboardSearchVisibility.withSearchVisibilityMutation {
                view.isHidden = !shouldShow
            }
            DashboardSettingsComponents.invalidateHostedSettingsRowHeight(for: view)
        }
    }

    private func fullWidthConstraint(for view: NSView, in stack: NSStackView) -> NSLayoutConstraint? {
        (view.constraints + stack.constraints).first { constraint in
            guard constraint.relation == .equal,
                  constraint.firstAttribute == .width,
                  constraint.secondAttribute == .width,
                  abs(constraint.multiplier - 1) < 0.001,
                  abs(constraint.constant) < 0.001 else {
                return false
            }
            let first = constraint.firstItem as AnyObject?
            let second = constraint.secondItem as AnyObject?
            return (first === view && second === stack)
                || (first === stack && second === view)
        }
    }

    private func shouldPreserveFullWidth(for view: NSView, in stack: NSStackView) -> Bool {
        view is SettingsSectionView
            || view.identifier == DashboardPageSearch.sectionIdentifier
            || view.identifier == DashboardPageSearch.globalSearchGroupIdentifier
            || stack.identifier == DashboardPageSearch.globalSearchGroupIdentifier
            || stack is SettingsSectionCardView
    }

    private func setEmptyStateHidden(_ hidden: Bool, in root: NSView) {
        if hidden {
            emptyStateView(in: root)?.isHidden = true
            return
        }
        let empty = emptyStateView(in: root) ?? installEmptyState(in: root)
        empty.isHidden = false
    }

    private func emptyStateView(in root: NSView) -> NSView? {
        if root.identifier == DashboardPageSearch.emptyStateIdentifier {
            return root
        }
        for child in root.subviews {
            if let found = emptyStateView(in: child) {
                return found
            }
        }
        if let stack = root as? NSStackView {
            return stack.arrangedSubviews.first {
                $0.identifier == DashboardPageSearch.emptyStateIdentifier
            }
        }
        return nil
    }

    private func installEmptyState(in root: NSView) -> NSView {
        let empty = SettingsSectionView(
            title: "",
            contentViews: [
                SettingsRowView(
                    title: tr(.keyDashboardSearchNoResults),
                    detail: tr(.keyDashboardSearchNoResultsDetail)
                )
            ]
        )
        empty.identifier = DashboardPageSearch.emptyStateIdentifier
        if let stack = contentStack(in: root) {
            stack.addView(empty, in: .top)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            empty.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 34),
                empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -34),
                empty.topAnchor.constraint(equalTo: root.topAnchor, constant: 52)
            ])
        }
        return empty
    }

    private func contentStack(in root: NSView) -> NSStackView? {
        if let stack = root as? NSStackView {
            return stack
        }
        return root.subviews.compactMap { $0 as? NSStackView }.first
    }

    private func hideAboutContentIfPresent(in root: NSView) {
        aboutContent(in: root).forEach { hideForSearch($0) }
    }

    private func restoreAboutContent(in root: NSView) {
        // Restoration of search-hidden views is handled by restoreSearchHiddens.
        _ = aboutContent(in: root)
    }

    private func aboutContent(in view: NSView) -> [NSView] {
        if view.identifier == DashboardPageSearch.aboutContentIdentifier {
            return [view]
        }
        return view.subviews.flatMap { aboutContent(in: $0) }
    }

    private func revealFirstMatch(in root: NSView) {
        guard let match = firstVisibleMatch(in: root) else { return }
        match.scrollToVisible(match.bounds)
    }

    private func firstVisibleMatch(in view: NSView) -> NSView? {
        if view.identifier == DashboardPageSearch.emptyStateIdentifier
            || DashboardSearchVisibility.isCollapsedForSearchLayout(view) {
            return nil
        }
        if DashboardPageSearch.isSearchableRow(view) {
            return view
        }
        for child in view.subviews {
            if let found = firstVisibleMatch(in: child) {
                return found
            }
        }
        return nil
    }
}
