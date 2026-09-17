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
        XCTAssertFalse(language.isHidden)
        XCTAssertTrue(startup.isHidden)
        XCTAssertTrue(refresh.isHidden || refresh.enclosingSection?.isHidden == true)
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
        XCTAssertFalse(languageRow.isHidden)
        let launchRow = try XCTUnwrap(
            settingsRow(
                titled: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin),
                in: composition.currentHostedPageContentForTesting()
            )
        )
        XCTAssertTrue(launchRow.isHidden)

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

private func settingsRow(titled title: String, in root: NSView) -> SettingsRowView? {
    if let row = root as? SettingsRowView, row.titleLabel.stringValue == title {
        return row
    }
    for child in root.subviews {
        if let found = settingsRow(titled: title, in: child) {
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
    if NSStringFromClass(type(of: root)) == className {
        return root
    }
    for child in root.subviews {
        if let found = firstDescendant(of: child, named: className) {
            return found
        }
    }
    return nil
}

private extension SettingsRowView {
    var enclosingSection: SettingsSectionView? { SettingsSectionView.enclosing(self) }
}
