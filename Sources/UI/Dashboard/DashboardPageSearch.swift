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
    private static var searchableRowKey: UInt8 = 0

    static func matches(_ text: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return text.localizedStandardContains(needle)
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
}

enum DashboardPageSearchMode {
    /// Settings pages: section headings and row titles.
    case titles
    /// Provider detail and About: currently visible copy.
    case visibleCopy
}

enum DashboardSettingsSearchCatalog {
    static func titles(for section: DashboardSection) -> [String] {
        var values = [section.title]
        values.append(contentsOf: keys(for: section).map { tr($0) })
        values.append(contentsOf: extraTitles(for: section))
        return values
    }

    static func matchingSections(query: String) -> [DashboardSection] {
        DashboardSection.allCases.filter { section in
            titles(for: section).contains { DashboardPageSearch.matches($0, query: query) }
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

final class DashboardPageSearchFilter {
    private let hiddenBySearch = NSHashTable<NSView>.weakObjects()
    private let originalStackVisibilityPriority = NSMapTable<NSView, NSNumber>.weakToStrongObjects()

    @discardableResult
    func apply(
        query: String,
        to root: NSView,
        pageTitle: String,
        mode: DashboardPageSearchMode
    ) -> Bool {
        restoreSearchHiddens()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            setEmptyStateHidden(true, in: root)
            restoreAboutContent(in: root)
            return true
        }
        if DashboardPageSearch.matches(pageTitle, query: needle) {
            setEmptyStateHidden(true, in: root)
            restoreAboutContent(in: root)
            return true
        }

        let matched: Bool
        switch mode {
        case .titles:
            matched = applyTitleFilter(query: needle, to: root)
        case .visibleCopy:
            matched = applyVisibleCopyFilter(query: needle, to: root)
        }
        setEmptyStateHidden(matched, in: root)
        if !matched {
            hideAboutContentIfPresent(in: root)
        } else {
            restoreAboutContent(in: root)
            revealFirstMatch(in: root)
        }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return matched
    }

    func pageContainsMatch(
        query: String,
        in root: NSView,
        pageTitle: String,
        mode: DashboardPageSearchMode
    ) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if DashboardPageSearch.matches(pageTitle, query: needle) {
            return true
        }
        switch mode {
        case .titles:
            return collectSections(in: root).contains { sectionMatches($0, query: needle) }
        case .visibleCopy:
            return visibleCopy(in: root).contains { DashboardPageSearch.matches($0, query: needle) }
        }
    }

    private func applyTitleFilter(query: String, to root: NSView) -> Bool {
        let sections = collectSections(in: root)
        guard !sections.isEmpty else {
            return applyVisibleCopyFilter(query: query, to: root)
        }
        var anyMatch = false
        for section in sections {
            let result = applySectionFilter(section, query: query)
            if result.countsAsHit {
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
            let matched = visibleCopy(in: root).contains {
                DashboardPageSearch.matches($0, query: query)
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
                anyMatch = true
            } else if result.hideSectionForSearch {
                hideForSearch(section)
            }
        }
        let unmatchedTopLevel = visibleCopy(in: root, skipping: sections).contains {
            DashboardPageSearch.matches($0, query: query)
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
        if sectionHeading(section).map({ DashboardPageSearch.matches($0, query: query) }) == true {
            return SectionFilterResult(
                countsAsHit: !DashboardSearchVisibility.isBusinessHidden(section),
                hideSectionForSearch: false
            )
        }
        guard let stack = rowStack(in: section) else {
            let visibleCopyMatches = includeVisibleCopy && visibleCopy(in: section).contains {
                DashboardPageSearch.matches($0, query: query)
            }
            let countsAsHit = visibleCopyMatches && !DashboardSearchVisibility.isBusinessHidden(section)
            return SectionFilterResult(
                countsAsHit: countsAsHit,
                hideSectionForSearch: !countsAsHit
            )
        }
        var visibleRowCount = 0
        for view in stack.arrangedSubviews where !(view is NSBox) {
            if rowContentMatches(view, query: query, includeVisibleCopy: includeVisibleCopy) {
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
        if sectionHeading(section).map({ DashboardPageSearch.matches($0, query: query) }) == true {
            return true
        }
        return rows(in: section).contains { rowMatches($0, query: query, includeVisibleCopy: false) }
    }

    private func rowMatches(
        _ row: NSView,
        query: String,
        includeVisibleCopy: Bool
    ) -> Bool {
        guard !DashboardSearchVisibility.isBusinessHidden(row) else { return false }
        return rowContentMatches(row, query: query, includeVisibleCopy: includeVisibleCopy)
    }

    private func rowContentMatches(
        _ row: NSView,
        query: String,
        includeVisibleCopy: Bool
    ) -> Bool {
        if DashboardPageSearch.matches(rowTitle(of: row), query: query) {
            return true
        }
        guard includeVisibleCopy else { return false }
        return searchableCopy(in: row).contains { DashboardPageSearch.matches($0, query: query) }
    }

    private func collectSections(in view: NSView) -> [NSView] {
        if view.identifier == DashboardPageSearch.emptyStateIdentifier {
            return []
        }
        if view is SettingsSectionView || view.identifier == DashboardPageSearch.sectionIdentifier {
            return [view]
        }
        if DashboardSearchVisibility.isBusinessHidden(view) {
            return []
        }
        return view.subviews.flatMap { collectSections(in: $0) }
    }

    private func rows(in section: NSView) -> [NSView] {
        if let native = section as? SettingsSectionView {
            return native.contentViews
        }
        return rowStack(in: section)?.arrangedSubviews.filter { !($0 is NSBox) } ?? []
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

    private func searchableCopy(in view: NSView) -> [String] {
        if view.identifier == DashboardPageSearch.emptyStateIdentifier {
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
        for child in view.subviews {
            values.append(contentsOf: searchableCopy(in: child))
        }
        return values
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
        DashboardSearchVisibility.withSearchVisibilityMutation {
            if let stack = view.superview as? NSStackView, stack.arrangedSubviews.contains(view) {
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
        DashboardSettingsComponents.invalidateHostedSettingsRowHeight(for: view)
    }

    @discardableResult
    private func restoreSearchHiddenView(_ view: NSView) -> NSStackView? {
        guard DashboardSearchVisibility.isSearchHidden(view) else { return nil }
        DashboardSearchVisibility.setSearchHidden(view, false)
        var restoredStack: NSStackView?
        DashboardSearchVisibility.withSearchVisibilityMutation {
            if let stack = view.superview as? NSStackView,
               stack.arrangedSubviews.contains(view),
               let stored = originalStackVisibilityPriority.object(forKey: view) {
                stack.setVisibilityPriority(
                    NSStackView.VisibilityPriority(rawValue: stored.floatValue),
                    for: view
                )
                restoredStack = stack
            }
        }
        originalStackVisibilityPriority.removeObject(forKey: view)
        hiddenBySearch.remove(view)
        DashboardSearchVisibility.restoreBusinessHidden(view)
        DashboardSettingsComponents.invalidateHostedSettingsRowHeight(for: view)
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
