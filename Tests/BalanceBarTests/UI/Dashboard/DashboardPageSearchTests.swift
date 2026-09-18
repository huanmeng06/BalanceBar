import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardPageSearchTests: XCTestCase {
    func testTitleFilterHidesUnmatchedRowsAndShowsEmptyState() {
        let language = SettingsRowView(title: "Language")
        let startup = SettingsRowView(title: "Startup")
        let refresh = SettingsRowView(title: "Balance Data")
        let stack = DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "Application", contentViews: [language, startup]),
            SettingsSectionView(title: "Refresh", contentViews: [refresh])
        ])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(
            filter.apply(
                query: "Language",
                to: stack,
                pageTitle: "General",
                mode: .titles
            )
        )
        XCTAssertFalse(isCollapsedForSearch(language))
        XCTAssertTrue(isCollapsedForSearch(startup))
        XCTAssertTrue(
            isCollapsedForSearch(refresh)
                || refresh.enclosingSection.map(isCollapsedForSearch) == true
        )
        XCTAssertNil(emptyState(in: stack))

        XCTAssertFalse(
            filter.apply(
                query: "zzznomatch",
                to: stack,
                pageTitle: "General",
                mode: .titles
            )
        )
        XCTAssertEqual(
            emptyState(in: stack)?.identifier,
            DashboardPageSearch.emptyStateIdentifier
        )
        XCTAssertFalse(try XCTUnwrap(emptyState(in: stack)).isHidden)

        XCTAssertTrue(
            filter.apply(
                query: "",
                to: stack,
                pageTitle: "General",
                mode: .titles
            )
        )
        XCTAssertFalse(isCollapsedForSearch(language))
        XCTAssertFalse(isCollapsedForSearch(startup))
        XCTAssertFalse(language.isHidden)
        XCTAssertFalse(startup.isHidden)
        XCTAssertTrue(emptyState(in: stack)?.isHidden != false)
    }

    func testCatalogJumpsToTheSectionThatOwnsTheTitle() {
        XCTAssertEqual(
            DashboardSettingsSearchCatalog.firstMatchingSection(
                query: tr(.keyDashboardMenuBarPagePreview)
            ),
            .menuBar
        )
        XCTAssertEqual(
            DashboardSettingsSearchCatalog.firstMatchingSection(
                query: tr(.keyDashboardGeneralAndRefreshPagesLanguage)
            ),
            .general
        )
        XCTAssertEqual(
            DashboardSettingsSearchCatalog.firstMatchingSection(
                query: tr(.keyDashboardAdvancedPageDiagnostics)
            ),
            .advanced
        )
        XCTAssertEqual(
            DashboardSettingsSearchCatalog.firstMatchingSection(
                query: tr(.keyDashboardMenuPageStatusLinks)
            ),
            .menu
        )
        XCTAssertEqual(
            DashboardSettingsSearchCatalog.firstMatchingSection(
                query: tr(.keyDashboardAboutPageGithubRepository)
            ),
            .about
        )
        XCTAssertNil(DashboardSettingsSearchCatalog.firstMatchingSection(query: "zzznomatch"))
    }

    func testToolbarSearchFiltersTheCurrentPageAndKeepsTheQueryOnPageChange() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-436-search-filter.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let searchItem = try XCTUnwrap(
            window.toolbar?.items.last as? NSSearchToolbarItem
        )
        XCTAssertEqual(
            searchItem.searchField.placeholderString,
            tr(.keyDashboardSearchPlaceholder)
        )

        composition.applySearchQueryForTesting(tr(.keyDashboardGeneralAndRefreshPagesLanguage))
        window.layoutIfNeeded()
        XCTAssertEqual(composition.section, .general)
        XCTAssertEqual(
            composition.searchQueryForTesting,
            tr(.keyDashboardGeneralAndRefreshPagesLanguage)
        )
        let languageRow = try XCTUnwrap(
            settingsRow(
                titled: tr(.keyDashboardGeneralAndRefreshPagesLanguage),
                in: composition.currentHostedPageContentForTesting()
            )
        )
        XCTAssertFalse(isCollapsedForSearch(languageRow))
        let launchRow = try XCTUnwrap(
            settingsRow(
                titled: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin),
                in: composition.currentHostedPageContentForTesting()
            )
        )
        XCTAssertTrue(isCollapsedForSearch(launchRow))

        composition.showSection(.menuBar)
        window.layoutIfNeeded()
        XCTAssertEqual(composition.section, .menuBar)
        XCTAssertEqual(
            composition.searchQueryForTesting,
            tr(.keyDashboardGeneralAndRefreshPagesLanguage)
        )
        XCTAssertFalse(try XCTUnwrap(emptyState(in: composition.currentHostedPageContentForTesting())).isHidden)

        composition.showSection(.general)
        window.layoutIfNeeded()
        XCTAssertFalse(
            try XCTUnwrap(
                settingsRow(
                    titled: tr(.keyDashboardGeneralAndRefreshPagesLanguage),
                    in: composition.currentHostedPageContentForTesting()
                )
            ).isHidden
        )
    }

    func testSearchJumpsToAnotherSectionThenClearsBackToTheOriginalPage() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-436-search-jump.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()

        composition.applySearchQueryForTesting(tr(.keyDashboardMenuBarPagePreview))
        window.layoutIfNeeded()
        XCTAssertEqual(composition.section, .menuBar)
        XCTAssertFalse(
            try XCTUnwrap(
                firstSection(
                    titled: tr(.keyDashboardMenuBarPagePreview),
                    in: composition.currentHostedPageContentForTesting()
                )
            ).isHidden
        )

        composition.applySearchQueryForTesting("")
        window.layoutIfNeeded()
        XCTAssertEqual(composition.section, .menuBar)
        XCTAssertEqual(composition.searchQueryForTesting, "")
        XCTAssertTrue(emptyState(in: composition.currentHostedPageContentForTesting())?.isHidden != false)
    }

    func testSearchItemStaysOnProviderPagesAndDoesNotUseAccessories() throws {
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true)
        ]
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in
                    DashboardScrollablePageViewController(
                        wrapping: DashboardSettingsComponents.makeSettingsPageContent([
                            SettingsSectionView(
                                title: "Usage",
                                contentViews: [SettingsRowView(title: "Remaining")]
                            )
                        ])
                    )
                },
                providerChoices: { choices },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer { controller.teardown() }
        controller.open()
        controller.showProvider("current")
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let identifiers = try XCTUnwrap(window.toolbar?.items.map(\.itemIdentifier))
        XCTAssertEqual(
            identifiers,
            [
                .flexibleSpace,
                .toggleSidebar,
                .sidebarTrackingSeparator,
                .flexibleSpace,
                DashboardToolbarController.searchItemIdentifier
            ]
        )
        XCTAssertTrue(window.toolbar?.items.last is NSSearchToolbarItem)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
    }

    func testEmptyStateUsesSettingsStructureWithoutCustomChrome() {
        let stack = DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(
                title: "Application",
                contentViews: [SettingsRowView(title: "Language")]
            )
        ])
        let filter = DashboardPageSearchFilter()
        XCTAssertFalse(
            filter.apply(
                query: "zzznomatch",
                to: stack,
                pageTitle: "General",
                mode: .titles
            )
        )
        let empty = try? XCTUnwrap(emptyState(in: stack) as? SettingsSectionView)
        XCTAssertNotNil(empty)
        XCTAssertFalse(empty?.wantsLayer == true && empty?.layer?.shadowOpacity ?? 0 > 0)
        XCTAssertNil(empty.flatMap { firstDescendant(of: $0, named: "NSGlassEffectView") })
    }

    func testBusinessHiddenRowIsNotATitleMatchAndDoesNotCreateAGhostSection() {
        let hidden = SettingsRowView(title: "Reverse Mouse Buttons")
        hidden.isHidden = true
        let visible = SettingsRowView(title: "Right Click")
        let section = SettingsSectionView(
            title: "Behavior",
            contentViews: [visible, hidden]
        )
        let stack = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()

        XCTAssertFalse(
            filter.apply(
                query: "Reverse Mouse Buttons",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertTrue(hidden.isHidden)
        XCTAssertTrue(isCollapsedForSearch(section))
        XCTAssertFalse(try XCTUnwrap(emptyState(in: stack)).isHidden)
        XCTAssertEqual(
            emptyState(in: stack)?.identifier,
            DashboardPageSearch.emptyStateIdentifier
        )
    }

    func testClearingSearchDoesNotRevealABusinessHiddenRow() {
        let hidden = SettingsRowView(title: "Reverse Mouse Buttons")
        hidden.isHidden = true
        let visible = SettingsRowView(title: "Right Click")
        let stack = DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "Behavior", contentViews: [visible, hidden])
        ])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(
            filter.apply(
                query: "Right Click",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertTrue(hidden.isHidden)
        XCTAssertFalse(isCollapsedForSearch(visible))

        XCTAssertTrue(
            filter.apply(
                query: "",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertTrue(hidden.isHidden)
        XCTAssertFalse(isCollapsedForSearch(visible))
        XCTAssertFalse(visible.isHidden)
    }

    func testClearingSearchKeepsARowHiddenIfBusinessHidesItDuringSearch() {
        let row = SettingsRowView(title: "Reverse Mouse Buttons")
        let other = SettingsRowView(title: "Right Click")
        let stack = DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "Behavior", contentViews: [other, row])
        ])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(
            filter.apply(
                query: "Right Click",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertTrue(isCollapsedForSearch(row))
        row.isHidden = true

        XCTAssertTrue(
            filter.apply(
                query: "",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertTrue(row.isHidden)
        XCTAssertFalse(isCollapsedForSearch(other))
        XCTAssertFalse(other.isHidden)
    }

    func testVisibleCopySkipsHiddenSubtreeCopy() {
        let hiddenField = NSTextField(labelWithString: "Hidden Provider Copy")
        hiddenField.isHidden = true
        let hiddenButton = NSButton(title: "Hidden Provider Button", target: nil, action: nil)
        hiddenButton.isHidden = true
        let hiddenHost = NSView()
        hiddenHost.addSubview(hiddenField)
        hiddenHost.addSubview(hiddenButton)
        hiddenHost.isHidden = true
        let visible = SettingsRowView(title: "Visible Row")
        let stack = DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "Usage", contentViews: [visible, hiddenHost])
        ])
        let filter = DashboardPageSearchFilter()

        XCTAssertFalse(
            filter.apply(
                query: "Hidden Provider Copy",
                to: stack,
                pageTitle: "Provider",
                mode: .visibleCopy
            )
        )
        XCTAssertFalse(
            filter.apply(
                query: "Hidden Provider Button",
                to: stack,
                pageTitle: "Provider",
                mode: .visibleCopy
            )
        )
        XCTAssertFalse(filter.pageContainsMatch(
            query: "Hidden Provider Copy",
            in: stack,
            pageTitle: "Provider",
            mode: .visibleCopy
        ))
        XCTAssertTrue(hiddenHost.isHidden)
        XCTAssertTrue(hiddenField.isHidden)
        XCTAssertTrue(hiddenButton.isHidden)
    }

    func testHiddenLunaReserveCardCopyIsNotAVisibleCopyMatch() {
        let card = LunaReserveCardView()
        card.update(
            quota: LunaReserveQuota(status: .available, remaining: 40, reset: "2h")
        )
        card.isHidden = true
        let visible = SettingsRowView(title: "Remaining")
        let stack = DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "Usage", contentViews: [visible, card])
        ])
        let filter = DashboardPageSearchFilter()

        XCTAssertFalse(
            filter.apply(
                query: tr(.keyLunaReserveTitle),
                to: stack,
                pageTitle: "Provider",
                mode: .visibleCopy
            )
        )
        XCTAssertTrue(card.isHidden)
        XCTAssertFalse(try XCTUnwrap(emptyState(in: stack)).isHidden)
    }

    func testHiddenReverseMouseButtonsRowOnMenuBarPageIsNotSearchable() throws {
        let suiteName = "DashboardPageSearchTests.ReverseMouse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.menuBarRightClickAction, .matchLeftClick)
        let page = DashboardMenuBarPage().make(.init(
            preferences: preferences,
            snapshot: Snapshot.official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay()
        ))
        let reverseTitle = tr(.keyDashboardMenuBarPageReverseMouseButtons)
        let reverseRow = try XCTUnwrap(row(containingTitle: reverseTitle, in: page))
        XCTAssertTrue(reverseRow.isHidden)

        let filter = DashboardPageSearchFilter()
        XCTAssertFalse(
            filter.apply(
                query: reverseTitle,
                to: page,
                pageTitle: DashboardSection.menuBar.title,
                mode: .titles
            )
        )
        XCTAssertTrue(reverseRow.isHidden)
        XCTAssertFalse(try XCTUnwrap(emptyState(in: page)).isHidden)

        XCTAssertTrue(
            filter.apply(
                query: "",
                to: page,
                pageTitle: DashboardSection.menuBar.title,
                mode: .titles
            )
        )
        XCTAssertTrue(reverseRow.isHidden)
    }

    func testHiddenResetCountdownRowIsNotSearchable() throws {
        let suiteName = "DashboardPageSearchTests.ResetCountdown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.showMenuBarAmount = false
        let page = DashboardMenuBarPage().make(.init(
            preferences: preferences,
            snapshot: Snapshot.official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay()
        ))
        let resetTitle = tr(.keyDashboardMenuBarPageResetCountdown)
        let resetRow = try XCTUnwrap(row(containingTitle: resetTitle, in: page))
        XCTAssertTrue(resetRow.isHidden)

        let filter = DashboardPageSearchFilter()
        XCTAssertFalse(
            filter.apply(
                query: resetTitle,
                to: page,
                pageTitle: DashboardSection.menuBar.title,
                mode: .titles
            )
        )
        XCTAssertTrue(resetRow.isHidden)
        XCTAssertFalse(try XCTUnwrap(emptyState(in: page)).isHidden)
    }

    func testHiddenAnimationFallbackWarningIsNotSearchable() {
        let suiteName = "DashboardPageSearchTests.AnimationFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let warning = DashboardMenuBarPage.animationFallbackWarningText()
        let page = DashboardMenuBarPage().make(.init(
            preferences: preferences,
            snapshot: Snapshot.official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay(),
            animationFallbackActive: false
        ))
        let warningRow = firstDescendant(of: page) {
            $0.identifier?.rawValue == DashboardMenuBarPage.animationFallbackWarningIdentifier + "Row"
        }
        XCTAssertEqual(warningRow?.isHidden, true)

        let filter = DashboardPageSearchFilter()
        XCTAssertFalse(
            filter.pageContainsMatch(
                query: warning,
                in: page,
                pageTitle: DashboardSection.menuBar.title,
                mode: .titles
            )
        )
        XCTAssertFalse(
            filter.apply(
                query: warning,
                to: page,
                pageTitle: DashboardSection.menuBar.title,
                mode: .visibleCopy
            )
        )
        XCTAssertEqual(warningRow?.isHidden, true)
    }

    func testCatalogCandidateIsRevalidatedAgainstLiveBusinessVisibility() throws {
        let previous = UserDefaults.standard.string(
            forKey: AppPreferences.menuBarRightClickActionKey
        )
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppPreferences.menuBarRightClickActionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferences.menuBarRightClickActionKey)
            }
        }
        UserDefaults.standard.set(
            MenuBarRightClickAction.matchLeftClick.rawValue,
            forKey: AppPreferences.menuBarRightClickActionKey
        )

        XCTAssertEqual(
            DashboardSettingsSearchCatalog.firstMatchingSection(
                query: tr(.keyDashboardMenuBarPageReverseMouseButtons)
            ),
            .menuBar
        )

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-436-search-ghost.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()

        composition.applySearchQueryForTesting(tr(.keyDashboardMenuBarPageReverseMouseButtons))
        window.layoutIfNeeded()
        XCTAssertEqual(composition.section, .general)
        XCTAssertFalse(
            try XCTUnwrap(emptyState(in: composition.currentHostedPageContentForTesting())).isHidden
        )

        composition.applySearchQueryForTesting("")
        window.layoutIfNeeded()
        composition.showSection(.menuBar)
        window.layoutIfNeeded()
        let reverseRow = try XCTUnwrap(
            row(
                containingTitle: tr(.keyDashboardMenuBarPageReverseMouseButtons),
                in: composition.currentHostedPageContentForTesting()
            )
        )
        XCTAssertTrue(reverseRow.isHidden)
    }
}

private func emptyState(in root: NSView) -> NSView? {
    if root.identifier == DashboardPageSearch.emptyStateIdentifier {
        return root
    }
    for child in root.subviews {
        if let found = emptyState(in: child) {
            return found
        }
    }
    return nil
}

private func isCollapsedForSearch(_ view: NSView) -> Bool {
    view.isHidden || DashboardSearchVisibility.isSearchHidden(view)
}

private func settingsRow(titled title: String, in root: NSView) -> SettingsRowView? {
    row(containingTitle: title, in: root) as? SettingsRowView
}

private func row(containingTitle title: String, in root: NSView) -> NSView? {
    if let row = root as? SettingsRowView, row.titleLabel.stringValue == title {
        return row
    }
    if root.identifier == DashboardPageSearch.rowIdentifier,
       firstLabel(in: root, matching: title) != nil {
        return root
    }
    for child in root.subviews {
        if let found = row(containingTitle: title, in: child) {
            return found
        }
    }
    return nil
}

private func firstLabel(in root: NSView, matching title: String) -> NSTextField? {
    if let field = root as? NSTextField, field.stringValue == title {
        return field
    }
    for child in root.subviews {
        if let found = firstLabel(in: child, matching: title) {
            return found
        }
    }
    return nil
}

private func firstSection(titled title: String, in root: NSView) -> NSView? {
    if let section = root as? SettingsSectionView, section.headingLabel.stringValue == title {
        return section
    }
    if root.identifier == DashboardPageSearch.sectionIdentifier,
       let heading = (root as? NSStackView)?.arrangedSubviews.first as? NSTextField,
       heading.stringValue == title {
        return root
    }
    for child in root.subviews {
        if let found = firstSection(titled: title, in: child) {
            return found
        }
    }
    return nil
}

private func firstDescendant(of root: NSView, named className: String) -> NSView? {
    firstDescendant(of: root) { NSStringFromClass(type(of: $0)) == className }
}

private func firstDescendant(of root: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
    if predicate(root) {
        return root
    }
    for child in root.subviews {
        if let found = firstDescendant(of: child, matching: predicate) {
            return found
        }
    }
    return nil
}

private extension SettingsRowView {
    var enclosingSection: SettingsSectionView? { SettingsSectionView.enclosing(self) }
}
