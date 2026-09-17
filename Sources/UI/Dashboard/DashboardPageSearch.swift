import AppKit

/// Dashboard settings search: toolbar query interpretation, page filtering,
/// and cross-section jump catalog. Empty results reuse SettingsSectionView.
enum DashboardPageSearch {
    static let sectionIdentifier = NSUserInterfaceItemIdentifier("dashboard.settings.section")
    static let rowIdentifier = NSUserInterfaceItemIdentifier("dashboard.settings.row")
    static let emptyStateIdentifier = NSUserInterfaceItemIdentifier("dashboard.search.emptyState")
    static let aboutContentIdentifier = NSUserInterfaceItemIdentifier("dashboard.about.content")

    static func matches(_ text: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return text.localizedStandardContains(needle)
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

    static func firstMatchingSection(query: String) -> DashboardSection? {
        DashboardSection.allCases.first { section in
            titles(for: section).contains { DashboardPageSearch.matches($0, query: query) }
        }
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
            return []
        }
    }
}

final class DashboardPageSearchFilter {
    private let hiddenBySearch = NSHashTable<NSView>.weakObjects()

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
            if applySectionFilter(section, query: query) {
                anyMatch = true
            } else {
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
            if applySectionFilter(section, query: query, includeVisibleCopy: true) {
                anyMatch = true
            } else {
                hideForSearch(section)
            }
        }
        let unmatchedTopLevel = visibleCopy(in: root, skipping: sections).contains {
            DashboardPageSearch.matches($0, query: query)
        }
        return anyMatch || unmatchedTopLevel
    }

    private func applySectionFilter(
        _ section: NSView,
        query: String,
        includeVisibleCopy: Bool = false
    ) -> Bool {
        if sectionHeading(section).map({ DashboardPageSearch.matches($0, query: query) }) == true {
            return true
        }
        guard let stack = rowStack(in: section) else {
            return includeVisibleCopy && visibleCopy(in: section).contains {
                DashboardPageSearch.matches($0, query: query)
            }
        }
        var visibleRowCount = 0
        for view in stack.arrangedSubviews where !(view is NSBox) {
            if rowMatches(view, query: query, includeVisibleCopy: includeVisibleCopy) {
                visibleRowCount += 1
            } else if !view.isHidden {
                hideForSearch(view)
            }
        }
        syncSeparators(in: stack)
        return visibleRowCount > 0
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
        if DashboardPageSearch.matches(rowTitle(of: row), query: query) {
            return true
        }
        guard includeVisibleCopy else { return false }
        return visibleCopy(in: row).contains { DashboardPageSearch.matches($0, query: query) }
    }

    private func collectSections(in view: NSView) -> [NSView] {
        if view.identifier == DashboardPageSearch.emptyStateIdentifier {
            return []
        }
        if view is SettingsSectionView || view.identifier == DashboardPageSearch.sectionIdentifier {
            return [view]
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
                    $0.identifier == DashboardPageSearch.rowIdentifier || $0 is SettingsRowView
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

    private func syncSeparators(in stack: NSStackView) {
        let arranged = stack.arrangedSubviews
        for (index, view) in arranged.enumerated() {
            guard view is NSBox else { continue }
            let previousVisible = arranged[..<index].reversed().first { !($0 is NSBox) }.map {
                !$0.isHidden
            } ?? false
            let nextVisible = arranged[(index + 1)...].first { !($0 is NSBox) }.map {
                !$0.isHidden
            } ?? false
            if !(previousVisible && nextVisible), !view.isHidden {
                hideForSearch(view)
            }
        }
    }

    private func hideForSearch(_ view: NSView) {
        guard !view.isHidden else { return }
        view.isHidden = true
        hiddenBySearch.add(view)
    }

    private func restoreSearchHiddens() {
        for view in hiddenBySearch.allObjects {
            view.isHidden = false
        }
        hiddenBySearch.removeAllObjects()
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
        if view.identifier == DashboardPageSearch.emptyStateIdentifier || view.isHidden {
            return nil
        }
        if view is SettingsRowView || view.identifier == DashboardPageSearch.rowIdentifier {
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
