import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardPageSearchTests: XCTestCase {
    func testRefreshItemInvokesSessionManualRefreshActionOnceAndSurvivesRebuild() throws {
        var refreshCount = 0
        let harness = DashboardShellTestHarness(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {},
                onManualRefresh: { refreshCount += 1 }
            )
        )
        defer { harness.teardown() }
        harness.open()

        let window = try XCTUnwrap(harness.window)
        let firstItem = try XCTUnwrap(
            window.toolbar?.items.first { $0.itemIdentifier == DashboardToolbarController.refreshItemIdentifier }
        )
        XCTAssertEqual(firstItem.label, tr(.keyDashboardGeneralAndRefreshPagesRefreshNow))
        XCTAssertEqual(firstItem.toolTip, tr(.keyDashboardGeneralAndRefreshPagesRefreshNow))
        XCTAssertNotNil(firstItem.image)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(firstItem.action), to: firstItem.target, from: firstItem))
        XCTAssertEqual(refreshCount, 1)

        harness.rebuild()
        let refreshItems = try XCTUnwrap(window.toolbar?.items.filter {
            $0.itemIdentifier == DashboardToolbarController.refreshItemIdentifier
        })
        XCTAssertEqual(refreshItems.count, 1)
        let rebuiltItem = try XCTUnwrap(refreshItems.first)
        XCTAssertTrue(rebuiltItem === firstItem)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(rebuiltItem.action), to: rebuiltItem.target, from: rebuiltItem))
        XCTAssertEqual(refreshCount, 2)
    }

    func testCompositionRefreshActionAndLabelsUpdateWhenToolbarIsReused() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        var refreshCount = 0
        let appDelegate = AppDelegate(repository: CCSwitchRepository(
            databaseURL: URL(fileURLWithPath: "/nonexistent/issue-459-refresh-localization.db")
        ))
        appDelegate.manualRefreshActionForTesting = { refreshCount += 1 }
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }

        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        let toolbar = try XCTUnwrap(window.toolbar)
        let englishItem = try XCTUnwrap(toolbar.items.first {
            $0.itemIdentifier == DashboardToolbarController.refreshItemIdentifier
        })
        let englishLabel = tr(.keyDashboardGeneralAndRefreshPagesRefreshNow, language: .english)
        XCTAssertEqual(englishItem.label, englishLabel)
        XCTAssertEqual(englishItem.toolTip, englishLabel)
        XCTAssertEqual(englishItem.image?.accessibilityDescription, englishLabel)

        let chineseLabel = tr(
            .keyDashboardGeneralAndRefreshPagesRefreshNow,
            language: .simplifiedChinese
        )
        AppLanguage.selected = .simplifiedChinese
        composition.rebuild()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let rebuiltItem = try XCTUnwrap(toolbar.items.first {
            $0.itemIdentifier == DashboardToolbarController.refreshItemIdentifier
        })
        XCTAssertTrue(rebuiltItem === englishItem)
        XCTAssertEqual(rebuiltItem.label, chineseLabel)
        XCTAssertEqual(rebuiltItem.paletteLabel, chineseLabel)
        XCTAssertEqual(rebuiltItem.toolTip, chineseLabel)
        XCTAssertEqual(rebuiltItem.image?.accessibilityDescription, chineseLabel)

        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(rebuiltItem.action),
            to: rebuiltItem.target,
            from: rebuiltItem
        ))
        XCTAssertEqual(refreshCount, 1)
    }

    func testSearchSlotTransitionsAndCancelPublishesEmptyExactlyOnce() async throws {
        let controller = DashboardToolbarController()
        let window = DashboardSearchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            controller.detach()
            window.close()
        }
        ApplicationWindowPresentation.presentInBackground(window)
        controller.install(on: window)
        var queries: [String] = []
        controller.onSearchQueryChanged = { queries.append($0) }
        for width: CGFloat in [1200, 800] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            XCTAssertFalse(controller.isSearchActive)
            let slot = try XCTUnwrap(window.toolbar?.items.last as? NSSearchToolbarItem)
            XCTAssertEqual(slot.toolTip, tr(.keyDashboardSearchPlaceholder))
            controller.beginSearch()
            await drainMainQueue()
            controller.controlTextDidBeginEditing(
                Notification(name: NSControl.textDidBeginEditingNotification, object: slot.searchField)
            )
            XCTAssertTrue(controller.isSearchActive)
            XCTAssertTrue(window.toolbar?.items.last === slot)
            let field = slot.searchField
            window.layoutIfNeeded()
            window.displayIfNeeded()
            XCTAssertEqual(slot.preferredWidthForSearchField, DashboardToolbarController.expandedSearchFieldWidth)
            XCTAssertFalse(field.sendsSearchStringImmediately)
            XCTAssertTrue(field.sendsWholeSearchString)
            field.stringValue = "Language"
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertEqual(controller.draftQuery, "Language")
            XCTAssertEqual(controller.searchQuery, "Language")
            _ = NSApp.sendAction(
                try XCTUnwrap(field.action),
                to: field.target,
                from: field
            )
            XCTAssertEqual(controller.searchQuery, "Language")
            controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
            await drainMainQueue()
            XCTAssertTrue(controller.isSearchActive)
            XCTAssertTrue(window.toolbar?.items.last === slot)
            XCTAssertEqual(controller.searchQuery, "Language")
            let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
            XCTAssertNotNil(cell.cancelButtonCell)
            field.stringValue = ""
            controller.searchFieldDidEndSearching(field)
            controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
            await drainMainQueue()
            XCTAssertEqual(controller.searchQuery, "")
            XCTAssertFalse(controller.isSearchActive)
            XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier), DashboardToolbarController.defaultItemIdentifiers)
        }
        XCTAssertEqual(queries, ["Language", "", "Language", ""])
    }

    func testDeletingLastCharacterClearsCurrentQueryBeforeCancel() async throws {
        let controller = DashboardToolbarController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            controller.detach()
            window.close()
        }
        controller.install(on: window)
        let field = try XCTUnwrap(
            DashboardSearchToolbarProbe.searchField(in: window.toolbar?.items.last)
        )
        controller.beginSearch()
        controller.controlTextDidBeginEditing(
            Notification(name: NSControl.textDidBeginEditingNotification, object: field)
        )
        controller.setQuery("a")
        field.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(controller.draftQuery, "")
        XCTAssertEqual(controller.searchQuery, "")
        XCTAssertTrue(controller.isSearchActive)
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        await drainMainQueue()
        XCTAssertFalse(controller.isSearchActive)
        controller.cancelSearch()
        XCTAssertFalse(controller.isSearchActive)
    }

    func testReinstallPreservesToolbarAndActiveSearchField() throws {
        let controller = DashboardToolbarController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            controller.detach()
            window.close()
        }
        controller.install(on: window)
        controller.setQuery("搜索")
        let toolbar = try XCTUnwrap(window.toolbar)
        let slot = try XCTUnwrap(toolbar.items.last)
        let field = try XCTUnwrap(DashboardSearchToolbarProbe.searchField(in: slot))
        field.stringValue = "搜索pin"
        controller.install(on: window)
        XCTAssertTrue(window.toolbar === toolbar)
        XCTAssertTrue(toolbar.items.last === slot)
        XCTAssertEqual(field.stringValue, "搜索pin")
        XCTAssertEqual(controller.searchQuery, "搜索")
        XCTAssertTrue(controller.isSearchActive)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), DashboardToolbarController.defaultItemIdentifiers)
    }

    func testEscapeDefersToMarkedTextAndOtherwiseEndsSearch() throws {
        let controller = DashboardToolbarController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            controller.detach()
            window.close()
        }
        controller.install(on: window)
        controller.setQuery("搜索")
        let field = try XCTUnwrap(
            DashboardSearchToolbarProbe.searchField(in: window.toolbar?.items.last)
        )
        let editor = NSTextView()
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(controller.searchQuery, "搜索")
        XCTAssertTrue(controller.isSearchActive)
        editor.unmarkText()
        XCTAssertTrue(controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(controller.searchQuery, "")
        XCTAssertFalse(controller.isSearchActive)
    }

    func testMarkedTextDoesNotPublishUntilCommitted() {
        final class ComposingField: NSSearchField {
            let editor = NSTextView()
            override func currentEditor() -> NSText? { editor }
        }
        let controller = DashboardToolbarController()
        let field = ComposingField()
        var queries: [String] = []
        controller.onSearchQueryChanged = { queries.append($0) }
        field.stringValue = "pin"
        field.editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(controller.searchQuery, "")
        field.editor.unmarkText()
        field.stringValue = "拼"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(queries, ["拼"])
        XCTAssertEqual(controller.searchQuery, "拼")
    }

    func testShellRebuildPreservesEditingAndCancelRestoresCurrentPage() throws {
        let appDelegate = AppDelegate(repository: CCSwitchRepository(
            databaseURL: URL(fileURLWithPath: "/nonexistent/issue-458-search.db")))
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        let owner = try XCTUnwrap(window.toolbar?.delegate as? DashboardToolbarController)
        owner.beginSearch()
        owner.setQuery(tr(.keyDashboardGeneralAndRefreshPagesLanguage))
        let toolbar = try XCTUnwrap(window.toolbar)
        let field = try XCTUnwrap(
            DashboardSearchToolbarProbe.searchField(in: toolbar.items.last)
        )
        if field.currentEditor() == nil {
            _ = window.makeFirstResponder(field)
        }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let query = owner.searchQuery
        composition.rebuild()
        XCTAssertTrue(window.toolbar === toolbar)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertTrue(owner.isSearchActive)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(owner.searchQuery, query)
        editor.unmarkText()
        composition.showSection(.menuBar)
        XCTAssertTrue(owner.isSearchActive)
        owner.cancelSearch()
        XCTAssertEqual(composition.section, .menuBar)
        XCTAssertEqual(composition.searchQueryForTesting, "")
        XCTAssertTrue(emptyState(in: composition.currentHostedPageContentForTesting())?.isHidden != false)
        XCTAssertFalse(owner.isSearchActive)
    }

    func testTwoSessionsKeepIndependentSearchItemsAndQueries() throws {
        let owners = [DashboardToolbarController(), DashboardToolbarController()]
        let windows = (0..<2).map { _ in
            NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
        }
        defer {
            zip(owners, windows).forEach { owner, window in
                owner.detach()
                window.close()
            }
        }
        for index in 0..<2 { owners[index].install(on: windows[index]) }
        XCTAssertNotEqual(windows[0].toolbar?.identifier, windows[1].toolbar?.identifier)
        owners[0].setQuery("Language")
        let firstItem = try XCTUnwrap(windows[0].toolbar?.items.last)
        owners[1].beginSearch()
        owners[1].cancelSearch()
        XCTAssertEqual(owners[0].searchQuery, "Language")
        XCTAssertTrue(windows[0].toolbar?.items.last === firstItem)
        XCTAssertFalse(owners[1].isSearchActive)
        for window in windows {
            XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier), DashboardToolbarController.defaultItemIdentifiers)
        }
    }

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

    func testDataRefreshKeepsTheExistingSearchProjectionUntilRematch() {
        let matching = SettingsRowView(title: "Target")
        let unmatched = SettingsRowView(title: "Other")
        let section = SettingsSectionView(title: "Settings", contentViews: [matching, unmatched])
        let root = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(filter.apply(query: "Target", to: root, pageTitle: "Settings", mode: .titles))
        XCTAssertFalse(isCollapsedForSearch(matching))
        XCTAssertTrue(isCollapsedForSearch(unmatched))

        filter.prepareForDataRefresh()
        XCTAssertFalse(isCollapsedForSearch(matching))
        XCTAssertTrue(isCollapsedForSearch(unmatched))

        filter.markSearchStructureChanged()
        XCTAssertFalse(isCollapsedForSearch(matching))
        XCTAssertTrue(isCollapsedForSearch(unmatched))
    }

    func testGlobalSearchStartsAtTopAndRefreshKeepsTheScrolledOffset() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-search-scroll-refresh.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 1000, height: 420))

        composition.applySearchQueryForTesting("状态")
        window.layoutIfNeeded()
        let page = try XCTUnwrap(composition.scrollablePageForTesting)
        XCTAssertEqual(
            page.scrollOffset,
            0,
            accuracy: 1,
            "the first global search starts at offset 0"
        )

        assertSearchRefreshPreservesScroll("refreshMenuPage", on: page, window: window) {
            composition.refreshMenuPage()
        }
        assertSearchRefreshPreservesScroll("refreshMenuBarPage", on: page, window: window) {
            composition.refreshMenuBarPage(snapshot: .placeholder)
        }
        assertSearchRefreshPreservesScroll("refreshMountedPage", on: page, window: window) {
            composition.refreshMountedPage(snapshot: .placeholder, refreshDate: nil, revision: 1)
        }

        page.restoreScrollOffset(250)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(page.scrollOffset, 100)
        composition.applySearchQueryForTesting("语言")
        window.layoutIfNeeded()
        XCTAssertEqual(
            page.scrollOffset,
            0,
            accuracy: 1,
            "changing the query starts at the top"
        )
    }

    private func assertSearchRefreshPreservesScroll(
        _ label: String,
        on page: DashboardScrollablePageViewController,
        window: NSWindow,
        refresh: () -> Void
    ) {
        page.restoreScrollOffset(250)
        window.layoutIfNeeded()
        let offsetBeforeRefresh = page.scrollOffset
        let documentHeight = page.scrollViewForTesting.documentView?.frame.height ?? 0
        XCTAssertEqual(
            offsetBeforeRefresh,
            250,
            accuracy: 2,
            "\(label) needs a scrolled search document; offset=\(offsetBeforeRefresh), documentHeight=\(documentHeight)"
        )

        refresh()
        window.layoutIfNeeded()
        XCTAssertEqual(
            page.scrollOffset,
            offsetBeforeRefresh,
            accuracy: 2,
            "\(label) must keep the user's scroll offset while rematching the same query"
        )
    }

    func testSettingsSearchIncludesSubtitlesOptionsAndOnlyLanguageIsCrossLanguage() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let languagePopup = NSPopUpButton()
        languagePopup.identifier = NSUserInterfaceItemIdentifier(AppLanguage.preferenceKey)
        languagePopup.addItems(withTitles: ["跟随系统", "简体中文", "English"])
        let languageRow = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesLanguage),
            detail: tr(.keyDashboardGeneralAndRefreshPagesChangesApplyToTheEntireInterfaceImmediately),
            accessoryView: languagePopup
        )

        let displayModePopup = NSPopUpButton()
        displayModePopup.addItems(withTitles: [
            tr(.keyDashboardMenuBarPageIconDisplayModeAlwaysVisible),
            tr(.keyDashboardMenuBarPageIconDisplayModeOnlyWhileRunning)
        ])
        let displayModeRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageIconDisplayMode),
            detail: tr(.keyDashboardMenuBarPageIconDisplayModeDescription),
            accessoryView: displayModePopup
        )
        let launchRow = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin),
            detail: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginDescription)
        )
        let root = DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "应用", contentViews: [languageRow, displayModeRow, launchRow])
        ])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(
            filter.apply(
                query: tr(.keyDashboardGeneralAndRefreshPagesChangesApplyToTheEntireInterfaceImmediately),
                to: root,
                pageTitle: "设置",
                mode: .titles
            )
        )
        XCTAssertFalse(isCollapsedForSearch(languageRow))
        XCTAssertTrue(isCollapsedForSearch(displayModeRow))

        XCTAssertTrue(
            filter.apply(
                query: tr(.keyDashboardMenuBarPageIconDisplayModeAlwaysVisible),
                to: root,
                pageTitle: "设置",
                mode: .titles
            )
        )
        XCTAssertFalse(isCollapsedForSearch(displayModeRow))

        XCTAssertTrue(filter.apply(query: "language", to: root, pageTitle: "设置", mode: .titles))
        XCTAssertTrue(filter.apply(query: "言語", to: root, pageTitle: "设置", mode: .titles))
        XCTAssertTrue(isCollapsedForSearch(launchRow))

        XCTAssertTrue(
            filter.apply(
                query: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin),
                to: root,
                pageTitle: "设置",
                mode: .titles
            )
        )
        XCTAssertFalse(isCollapsedForSearch(launchRow))
        XCTAssertFalse(
            DashboardSettingsSearchCatalog.matchingSections(query: "Launch at Login")
                .contains(.general)
        )
        XCTAssertEqual(
            DashboardSettingsSearchCatalog.firstMatchingSection(query: "言語"),
            .general
        )
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

    func testSearchMatcherUsesNativeLocalizedSubstringSemantics() {
        XCTAssertTrue(DashboardPageSearch.matches("Language", query: "language"))
        XCTAssertTrue(DashboardPageSearch.matches("Menu Bar Font Size", query: "Font"))
        XCTAssertFalse(DashboardPageSearch.matches("Menu Bar Font Size", query: "font menu"))
        XCTAssertFalse(DashboardPageSearch.matches("Menu Bar Font Size", query: "menubarfont"))
        XCTAssertFalse(DashboardPageSearch.matches("Language", query: "langauge"))
        XCTAssertFalse(DashboardPageSearch.matches("Launch at Login", query: "开机启动"))
        XCTAssertNil(DashboardSettingsSearchCatalog.firstMatchingSection(query: "langauge"))
        XCTAssertFalse(DashboardPageSearch.matches("Language", query: "zzznomatch"))
    }

    func testSearchDocumentsUseNativeSubstringDataAndHonorCancellation() {
        let documents = [
            DashboardSearchDocument(
                id: "language",
                sectionID: "general",
                texts: ["Language"],
                supportingTexts: ["语言"],
                businessVisible: true,
                order: 0
            ),
            DashboardSearchDocument(
                id: "hidden",
                sectionID: "general",
                texts: ["Language"],
                supportingTexts: [],
                businessVisible: false,
                order: 1
            )
        ]

        XCTAssertEqual(
            DashboardPageSearch.matchDocuments(documents, query: "lang")
                .map(\.documentID),
            ["language"]
        )
        XCTAssertTrue(
            DashboardPageSearch.matchDocuments(
                documents,
                query: "language",
                isCancelled: { true }
            ).isEmpty
        )
    }

    func testFreshDynamicStatusLinkQuerySelectsMenuSection() throws {
        let defaults = UserDefaults.standard
        let previousData = defaults.data(forKey: "statusLinks")
        let previousStatusMenu = defaults.object(forKey: "showStatusMenu")
        defer {
            if let previousData {
                defaults.set(previousData, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
            if let previousStatusMenu {
                defaults.set(previousStatusMenu, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
        }
        defaults.set(
            try JSONEncoder().encode([
                StatusLink(title: "Tibo", url: "https://tibo.example"),
                StatusLink(title: "Codex", url: "https://codex.example")
            ]),
            forKey: "statusLinks"
        )
        defaults.set(true, forKey: "showStatusMenu")

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-dynamic-status-links.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 1000, height: 700))

        func statusLinksEditor(in root: NSView) -> StatusLinksEditorHostingView? {
            if let editor = root as? StatusLinksEditorHostingView { return editor }
            for child in root.subviews {
                if let editor = statusLinksEditor(in: child) { return editor }
            }
            return nil
        }

        for query in ["Tibo", "Codex"] {
            composition.applySearchQueryForTesting(query)
            let root = composition.currentHostedPageContentForTesting()
            let editor = statusLinksEditor(in: root)
            XCTAssertTrue(
                editor?.isHidden == false,
                "\(query): editorVisible=\(editor?.isHidden == false), materialized=\(DashboardPageSearchDiagnostics.globalSearchPagesMaterializedCount)"
            )
        }
    }

    func testSearchMatcherDoesNotCombineKeywordsAcrossRows() {
        let first = SettingsRowView(title: "Menu")
        let second = SettingsRowView(title: "Font Size")
        let section = SettingsSectionView(title: "Settings", contentViews: [first, second])
        let stack = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()

        XCTAssertFalse(
            filter.apply(
                query: "font menu",
                to: stack,
                pageTitle: "Settings",
                mode: .titles
            )
        )
        XCTAssertTrue(first.isHidden)
        XCTAssertTrue(second.isHidden)
    }

    func testQuotaSearchFindsDigitsInDescriptionAndUnselectedChoices() {
        let fiveHourQuota = tr(.keyDashboardMenuBarPageFiveHourQuota)
        let sevenDayQuota = tr(.keyDashboardMenuBarPageSevenDayQuota)
        let options = NSPopUpButton()
        options.addItems(withTitles: [fiveHourQuota, sevenDayQuota])
        let quota = SettingsRowView(
            title: "优先显示额度",
            detail: "选择菜单栏显示的额度",
            accessoryView: options
        )
        let other = SettingsRowView(title: "菜单栏字号")
        let section = SettingsSectionView(title: "额度与重置", contentViews: [quota, other])
        let root = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(DashboardSettingsSearchCatalog.matchingSections(query: "5").contains(.menuBar))
        XCTAssertTrue(DashboardSettingsSearchCatalog.matchingSections(query: "7").contains(.menuBar))
        for query in [fiveHourQuota, sevenDayQuota] {
            XCTAssertEqual(DashboardSettingsSearchCatalog.firstMatchingSection(query: query), .menuBar)
            XCTAssertTrue(filter.apply(query: query, to: root, pageTitle: "菜单栏", mode: .titles))
            XCTAssertFalse(isCollapsedForSearch(quota), query)
            XCTAssertTrue(isCollapsedForSearch(other), query)
        }
        quota.isHidden = true
        XCTAssertFalse(filter.pageContainsMatch(
            query: "5", in: root, pageTitle: "菜单栏", mode: .titles
        ))
        XCTAssertFalse(filter.apply(query: "5", to: root, pageTitle: "菜单栏", mode: .titles))
        XCTAssertTrue(filter.apply(query: "", to: root, pageTitle: "菜单栏", mode: .titles))
        XCTAssertTrue(quota.isHidden)
        XCTAssertFalse(other.isHidden)
    }

    func testNativeSearchResultsRemainAvailableFromEachStartingSection() throws {
        func rows(
            startingAt section: DashboardSection,
            query: String
        ) throws -> [String] {
            let appDelegate = AppDelegate(
                repository: CCSwitchRepository(
                    databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-global-search.db")
                )
            )
            let composition = appDelegate.dashboardCompositionForTesting
            defer { composition.teardownForTesting() }
            let window = try XCTUnwrap(composition.makeWindowForTesting(showing: section))
            window.setContentSize(NSSize(width: 1000, height: 700))
            composition.applySearchQueryForTesting(query)
            window.layoutIfNeeded()
            return visibleSearchableRowTitles(in: composition.currentHostedPageContentForTesting())
        }

        for query in [
            tr(.keyDashboardGeneralAndRefreshPagesLanguage),
            tr(.keyDashboardMenuBarPagePreview),
            tr(.keyDashboardMenuPageStatusLinks)
        ] {
            let generalStartRows = try rows(startingAt: .general, query: query)
            for startingSection in [.menuBar, .menu, .advanced] as [DashboardSection] {
                let startRows = try rows(startingAt: startingSection, query: query)
                XCTAssertEqual(startRows, generalStartRows, "query: \(query), section: \(startingSection)")
            }
        }
    }

    func testAboutToSettingsWithActiveQueryEntersGlobalSearchWithoutRestoringAbout() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-about-navigation.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .about))
        window.setContentSize(NSSize(width: 1000, height: 700))

        composition.applySearchQueryForTesting(
            tr(.keyDashboardGeneralAndRefreshPagesLanguage)
        )
        let aboutRoot = composition.currentHostedPageContentForTesting()

        composition.showSection(.general)

        XCTAssertEqual(composition.section, .general)
        XCTAssertFalse(composition.currentHostedPageContentForTesting() === aboutRoot)
        XCTAssertFalse(visibleSearchableRowTitles(in: composition.currentHostedPageContentForTesting()).isEmpty)

        composition.applySearchQueryForTesting("")
        XCTAssertEqual(composition.section, .general)
        XCTAssertFalse(composition.currentHostedPageContentForTesting() === aboutRoot)
    }

    func testGlobalSearchSingleCharacterMaterializesCompleteCatalogCandidates() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-search-materialization.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 1000, height: 700))

        for query in ["t", "a"] {
            DashboardPageSearchDiagnostics.reset()
            composition.applySearchQueryForTesting(query)

            let expectedSections = Set(
                DashboardSettingsSearchCatalog.rankedSections(query: query)
                    .map(\.section)
                    .filter { $0 != .about }
            ).union([.general])
            XCTAssertGreaterThanOrEqual(
                DashboardPageSearchDiagnostics.globalSearchPagesMaterializedCount,
                expectedSections.count,
                "single-character candidate completeness (query: \(query))"
            )
            if query == "t" {
                composition.applySearchQueryForTesting("ti")
            }
            composition.applySearchQueryForTesting("")
        }
    }

    func testSteadyStateGlobalSearchReusesIndexAndDoesNotSynchronouslyLayout() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-search-steady-state.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 1000, height: 700))

        DashboardPageSearchDiagnostics.reset()
        composition.applySearchQueryForTesting("font")
        let indexBuildsAfterFirstQuery = DashboardPageSearchDiagnostics.searchIndexBuildCount
        let layoutsAfterFirstQuery = DashboardPageSearchDiagnostics.synchronousLayoutCount
        XCTAssertGreaterThan(indexBuildsAfterFirstQuery, 0)
        XCTAssertGreaterThan(layoutsAfterFirstQuery, 0)

        composition.applySearchQueryForTesting("font menu")

        XCTAssertEqual(
            DashboardPageSearchDiagnostics.searchIndexBuildCount,
            indexBuildsAfterFirstQuery,
            "steady-state query changes must reuse the mounted search index"
        )
        XCTAssertEqual(
            DashboardPageSearchDiagnostics.synchronousLayoutCount,
            layoutsAfterFirstQuery,
            "steady-state query changes must leave layout to the normal display cycle"
        )
    }

    func testGlobalSearchAdvancedProjectionDoesNotCreateLogViewer() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-search-advanced.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 1000, height: 700))

        composition.applySearchQueryForTesting("diagnostics")

        func containsLogViewerHost(_ view: NSView) -> Bool {
            if view.identifier == DashboardAdvancedPage.logViewerHostIdentifier { return true }
            return view.subviews.contains(where: containsLogViewerHost)
        }
        XCTAssertFalse(
            containsLogViewerHost(composition.currentHostedPageContentForTesting()),
            "search projections must not create the Advanced page's NSText log viewer"
        )
    }

    func testGlobalSearchUsesStackVisibilityToRemoveProjectionSpacing() throws {
        func makeGroup(sectionTitles: [String]) -> NSStackView {
            let group = NSStackView()
            group.identifier = DashboardPageSearch.globalSearchGroupIdentifier
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = DashboardSettingsComponents.settingsSectionSpacing
            group.distribution = .gravityAreas
            group.detachesHiddenViews = false
            group.translatesAutoresizingMaskIntoConstraints = false
            for title in sectionTitles {
                let section = SettingsSectionView(
                    title: title,
                    contentViews: [SettingsRowView(title: "\(title) option")]
                )
                group.addArrangedSubview(section)
                section.translatesAutoresizingMaskIntoConstraints = false
                section.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            }
            return group
        }

        let matchingGroup = makeGroup(sectionTitles: ["Progress", "Banked", "Items", "Quick", "Tibo"])
        let staleGroup = makeGroup(sectionTitles: ["Other"])
        let root = NSStackView(views: [matchingGroup, staleGroup])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = DashboardSettingsComponents.settingsSectionSpacing
        root.distribution = .gravityAreas
        root.detachesHiddenViews = false
        root.translatesAutoresizingMaskIntoConstraints = false
        root.frame = NSRect(x: 0, y: 0, width: 700, height: 2_000)
        matchingGroup.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        staleGroup.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let filter = DashboardPageSearchFilter()
        XCTAssertTrue(filter.apply(query: "Tibo", to: root, pageTitle: "", mode: .titles))
        root.layoutSubtreeIfNeeded()

        let visibleSections = matchingGroup.arrangedSubviews.filter {
            !DashboardSearchVisibility.isSearchHidden($0)
                && !DashboardSearchVisibility.isBusinessHidden($0)
        }
        XCTAssertEqual(visibleSections.count, 1)
        XCTAssertEqual(
            matchingGroup.arrangedSubviews.filter {
                matchingGroup.visibilityPriority(for: $0) == .notVisible
            }.count,
            4
        )
        let visibleHeight = visibleSections[0].fittingSize.height
        XCTAssertLessThanOrEqual(
            matchingGroup.fittingSize.height,
            visibleHeight + 1,
            "hidden global sections must not leave their 28pt stack spacing"
        )
        XCTAssertEqual(root.visibilityPriority(for: staleGroup), .notVisible)
        XCTAssertLessThanOrEqual(
            root.fittingSize.height,
            matchingGroup.fittingSize.height + 1,
            "a hidden global group must not leave its 12pt outer spacing"
        )
    }

    func testGlobalSearchInvalidatesOwnerChainWhenRowsCollapse() throws {
        let rows = [
            SettingsRowView(title: "First"),
            SettingsRowView(title: "Second"),
            SettingsRowView(title: "Third")
        ]
        let section = SettingsSectionView(title: "Startup", contentViews: rows)
        let group = NSStackView(views: [section])
        group.identifier = DashboardPageSearch.globalSearchGroupIdentifier
        group.orientation = .vertical
        group.alignment = .leading
        group.distribution = .gravityAreas
        group.detachesHiddenViews = true
        group.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        section.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true

        let filter = DashboardPageSearchFilter()
        XCTAssertTrue(filter.apply(query: "Third", to: group, pageTitle: "", mode: .titles))
        group.layoutSubtreeIfNeeded()

        XCTAssertFalse(rows[2].isHidden)
        XCTAssertTrue(rows[0].isHidden)
        XCTAssertTrue(rows[1].isHidden)
        XCTAssertLessThanOrEqual(
            section.cardView.frame.height,
            rows[2].frame.height + 2,
            "collapsing rows must invalidate card, section and global owner intrinsic sizes"
        )
        XCTAssertLessThanOrEqual(rows[2].frame.height, 100)
    }

    func testGlobalSearchResizeWhileHiddenKeepsFirstRestoreHeight() async throws {
        let target = SettingsRowView(title: "Target")
        let other = SettingsRowView(title: "Other")
        let section = SettingsSectionView(title: "Resize", contentViews: [target, other])
        let group = NSStackView(views: [section])
        group.identifier = DashboardPageSearch.globalSearchGroupIdentifier
        group.orientation = .vertical
        group.alignment = .leading
        group.distribution = .gravityAreas
        group.detachesHiddenViews = true
        group.frame = NSRect(x: 0, y: 0, width: 1_000, height: 900)
        section.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true

        let filter = DashboardPageSearchFilter()
        XCTAssertTrue(filter.apply(query: "Other", to: group, pageTitle: "", mode: .titles))
        group.layoutSubtreeIfNeeded()

        group.setFrameSize(NSSize(width: 420, height: group.frame.height))
        group.needsLayout = true
        group.layoutSubtreeIfNeeded()

        XCTAssertTrue(filter.apply(query: "Target", to: group, pageTitle: "", mode: .titles))
        let firstRowHeight = target.frame.height
        let firstCardHeight = section.cardView.frame.height

        await drainMainQueue()
        group.needsLayout = true
        group.layoutSubtreeIfNeeded()

        XCTAssertEqual(target.frame.height, firstRowHeight, accuracy: 1)
        XCTAssertEqual(section.cardView.frame.height, firstCardHeight, accuracy: 1)
        XCTAssertLessThanOrEqual(target.frame.height, 100)
    }

    func testGlobalSearchDirectAndIncrementalQueriesConverge() throws {
        let previousLanguage = AppLanguage.selected
        AppLanguage.selected = .english
        defer { AppLanguage.selected = previousLanguage }
        let query = tr(.keyDashboardGeneralAndRefreshPagesLanguage)
        let prefixes = stride(from: 1, through: query.count, by: 1).map {
            String(query.prefix($0))
        }

        func snapshot(_ root: NSView) -> ([String], [CGFloat], [String], [CGFloat]) {
            var rows: [String] = []
            var groupHeights: [CGFloat] = []
            var rowFrames: [String] = []
            var rowHeights: [CGFloat] = []
            var visited = Set<ObjectIdentifier>()
            func walk(_ view: NSView) {
                guard visited.insert(ObjectIdentifier(view)).inserted else { return }
                if DashboardPageSearch.isSearchableRow(view), !isCollapsedForSearch(view) {
                    if let row = view as? SettingsRowView {
                        rows.append(row.titleLabel.stringValue)
                        rowHeights.append(row.frame.height)
                        rowFrames.append(
                            "\(row.titleLabel.stringValue)=row:\(NSStringFromRect(row.frame)) content:\(NSStringFromRect(row.contentStack.frame)) labels:\(NSStringFromRect(row.labelsStack.frame)) title:\(NSStringFromRect(row.titleLabel.frame)) detail:\(NSStringFromRect(row.detailLabel.frame))"
                        )
                    }
                }
                if view.identifier == DashboardPageSearch.globalSearchGroupIdentifier,
                   !isCollapsedForSearch(view) {
                    groupHeights.append(view.fittingSize.height)
                }
                for child in view.subviews {
                    walk(child)
                }
                if let stack = view as? NSStackView {
                    for child in stack.arrangedSubviews {
                        walk(child)
                    }
                }
            }
            walk(root)
            return (rows, groupHeights, rowFrames, rowHeights)
        }

        let typedAppDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-typed-search.db")
            )
        )
        let typedComposition = typedAppDelegate.dashboardCompositionForTesting
        defer { typedComposition.teardownForTesting() }
        let typedWindow = try XCTUnwrap(typedComposition.makeWindowForTesting(showing: .general))
        typedWindow.setContentSize(NSSize(width: 1_000, height: 700))
        for prefix in prefixes {
            typedComposition.applySearchQueryForTesting(prefix)
            typedWindow.layoutIfNeeded()
        }
        let typedSnapshot = snapshot(typedComposition.currentHostedPageContentForTesting())

        let directAppDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-direct-search.db")
            )
        )
        let directComposition = directAppDelegate.dashboardCompositionForTesting
        defer { directComposition.teardownForTesting() }
        let directWindow = try XCTUnwrap(directComposition.makeWindowForTesting(showing: .general))
        directWindow.setContentSize(NSSize(width: 1_000, height: 700))
        directComposition.applySearchQueryForTesting(query)
        directWindow.layoutIfNeeded()
        let directSnapshot = snapshot(directComposition.currentHostedPageContentForTesting())

        XCTAssertEqual(typedSnapshot.0, directSnapshot.0)
        XCTAssertEqual(typedSnapshot.1.count, directSnapshot.1.count)
        XCTAssertEqual(typedSnapshot.3.count, directSnapshot.3.count)
        for (typedHeight, directHeight) in zip(typedSnapshot.3, directSnapshot.3) {
            XCTAssertEqual(typedHeight, directHeight, accuracy: 1.0)
        }
        XCTAssertTrue(typedSnapshot.3.allSatisfy { $0 <= 100 })
        for (typedHeight, directHeight) in zip(typedSnapshot.1, directSnapshot.1) {
            XCTAssertEqual(
                typedHeight,
                directHeight,
                accuracy: 1.0,
                "typed heights=\(typedSnapshot.1), direct heights=\(directSnapshot.1), typed rows=\(typedSnapshot.2), direct rows=\(directSnapshot.2)"
            )
        }
    }

    func testGlobalSearchRestoresSectionWidthsAfterQueryBroadens() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-search-width.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 1_000, height: 700))

        func visibleSectionWidths(in root: NSView) -> [(String, CGFloat, CGFloat)] {
            var result: [(String, CGFloat, CGFloat)] = []
            var visited = Set<ObjectIdentifier>()
            func walk(_ view: NSView) {
                guard visited.insert(ObjectIdentifier(view)).inserted else { return }
                if let section = view as? SettingsSectionView,
                   !DashboardSearchVisibility.isSearchHidden(section),
                   !DashboardSearchVisibility.isBusinessHidden(section),
                   let stack = section.superview as? NSStackView {
                    result.append((section.headingLabel.stringValue, section.frame.width, stack.frame.width))
                }
                for child in view.subviews {
                    walk(child)
                }
                if let stack = view as? NSStackView {
                    for child in stack.arrangedSubviews {
                        walk(child)
                    }
                }
            }
            walk(root)
            return result
        }

        func settle() -> [(String, CGFloat, CGFloat)] {
            window.layoutIfNeeded()
            let root = composition.currentHostedPageContentForTesting()
            root.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            return visibleSectionWidths(in: root)
        }

        composition.applySearchQueryForTesting("t")
        let initial = settle()
        XCTAssertFalse(initial.isEmpty)

        composition.applySearchQueryForTesting("ti")
        _ = settle()
        composition.applySearchQueryForTesting("t")
        let restored = settle()

        XCTAssertEqual(restored.count, initial.count)
        for (title, width, ownerWidth) in restored {
            XCTAssertGreaterThan(width, 300, "restored section \(title) became a narrow column")
            XCTAssertEqual(width, ownerWidth, accuracy: 1.0, "section \(title) lost its full-width constraint")
        }
    }

    func testGlobalSearchUsesSharedSectionSpacingAcrossGroups() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-search-spacing.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 1_000, height: 700))
        composition.applySearchQueryForTesting("Menu")
        window.layoutIfNeeded()

        let root = try XCTUnwrap(composition.currentHostedPageContentForTesting() as? NSStackView)
        XCTAssertEqual(root.spacing, DashboardSettingsComponents.settingsSectionSpacing)
        var groups: [NSStackView] = []
        var visited = Set<ObjectIdentifier>()
        func collect(_ view: NSView) {
            guard visited.insert(ObjectIdentifier(view)).inserted else { return }
            if view.identifier == DashboardPageSearch.globalSearchGroupIdentifier,
               let group = view as? NSStackView {
                groups.append(group)
            }
            for child in view.subviews {
                collect(child)
            }
            if let stack = view as? NSStackView {
                for child in stack.arrangedSubviews {
                    collect(child)
                }
            }
        }
        collect(root)
        XCTAssertGreaterThanOrEqual(groups.count, 1)
        for group in groups {
            XCTAssertEqual(group.spacing, DashboardSettingsComponents.settingsSectionSpacing)
        }
    }

    func testSearchDoesNotExpandRefreshIntervalPopupsOrTheirRow() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-refresh-layout.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 705, height: 509))

        func settleLayout() {
            for _ in 0..<3 {
                window.layoutIfNeeded()
                composition.currentHostedPageContentForTesting().layoutSubtreeIfNeeded()
                SettingsRowView.flushPendingWrappingHeightCommits(
                    in: composition.currentHostedPageContentForTesting()
                )
            }
        }
        settleLayout()

        let root = composition.currentHostedPageContentForTesting()
        let row = try XCTUnwrap(settingsRow(
            titled: tr(.keyDashboardGeneralAndRefreshPagesBalanceUpdatesDuringTasks),
            in: root
        ))
        let section = try XCTUnwrap(SettingsSectionView.enclosing(row))
        let active = try XCTUnwrap(firstDescendant(of: row) {
            $0.identifier?.rawValue == "codexUsageRefreshInterval"
        } as? NSPopUpButton)
        let trailing = try XCTUnwrap(firstDescendant(of: row) {
            $0.identifier?.rawValue == "postCodexRefreshDuration"
        } as? NSPopUpButton)
        let originalPopupSizes = [active.frame.size, trailing.frame.size]
        let originalRowHeight = row.frame.height
        let originalCardHeight = section.cardView.frame.height
        let originalRowWidth = row.bounds.width
        let originalContentOrientation = row.contentStack.orientation
        let originalDetailWidth = row.detailLabel.preferredMaxLayoutWidth
        let originalDetailHeight = row.detailLabel.frame.height

        XCTAssertLessThan(active.frame.width, 180)
        XCTAssertLessThan(trailing.frame.width, 180)
        XCTAssertLessThan(originalRowHeight, 220)

        composition.applySearchQueryForTesting(
            tr(.keyDashboardGeneralAndRefreshPagesBalanceUpdatesDuringTasks)
        )
        settleLayout()
        let resultRoot = composition.currentHostedPageContentForTesting()
        let resultRow = try XCTUnwrap(settingsRow(
            titled: tr(.keyDashboardGeneralAndRefreshPagesBalanceUpdatesDuringTasks),
            in: resultRoot
        ))
        let resultSection = try XCTUnwrap(SettingsSectionView.enclosing(resultRow))
        let resultActive = try XCTUnwrap(firstDescendant(of: resultRow) {
            $0.identifier?.rawValue == "codexUsageRefreshInterval"
        } as? NSPopUpButton)
        let resultTrailing = try XCTUnwrap(firstDescendant(of: resultRow) {
            $0.identifier?.rawValue == "postCodexRefreshDuration"
        } as? NSPopUpButton)
        let adaptiveState = resultRow.accessoryView as? DashboardAdaptiveControlsStackView

        XCTAssertFalse(isCollapsedForSearch(resultRow))
        XCTAssertEqual(resultActive.frame.size.width, originalPopupSizes[0].width, accuracy: 1)
        XCTAssertEqual(resultActive.frame.size.height, originalPopupSizes[0].height, accuracy: 1)
        XCTAssertEqual(resultTrailing.frame.size.width, originalPopupSizes[1].width, accuracy: 1)
        XCTAssertEqual(resultTrailing.frame.size.height, originalPopupSizes[1].height, accuracy: 1)
        XCTAssertEqual(
            resultRow.frame.height,
            originalRowHeight,
            accuracy: 2,
            "section=\(composition.section), row width \(originalRowWidth)->\(resultRow.bounds.width), content \(resultRow.contentStack.frame), orientation \(originalContentOrientation.rawValue)->\(resultRow.contentStack.orientation.rawValue), intrinsic=\(resultRow.intrinsicContentSize.height), detail width \(originalDetailWidth)->\(resultRow.detailLabel.preferredMaxLayoutWidth), detail height \(originalDetailHeight)->\(resultRow.detailLabel.frame.height), labels \(resultRow.labelsStack.frame), accessory \(String(describing: resultRow.accessoryView?.frame)), adaptiveVertical=\(String(describing: adaptiveState?.stacksControlsVertically))"
        )
        XCTAssertLessThan(resultSection.cardView.frame.height, originalCardHeight - 40)
        XCTAssertLessThanOrEqual(sectionHeadingToCardGap(in: resultSection), 16)
    }

    func testSearchKeepsApplicationHeadingCloseToItsResultCard() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-heading-gap.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 855, height: 457))

        composition.applySearchQueryForTesting(tr(.keyDashboardGeneralAndRefreshPagesLanguage))
        window.layoutIfNeeded()
        let root = composition.currentHostedPageContentForTesting()
        root.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(settingsRow(
            titled: tr(.keyDashboardGeneralAndRefreshPagesLanguage),
            in: root
        ))
        let section = try XCTUnwrap(SettingsSectionView.enclosing(row))

        XCTAssertLessThanOrEqual(
            sectionHeadingToCardGap(in: section),
            SettingsSectionView.headingToCardSpacing + 1,
            "search should keep the section heading and its result card together; section=\(section.frame), intrinsic=\(section.intrinsicContentSize), stack=\(section.contentStack.frame), heading=\(section.headingLabel.frame), card=\(section.cardView.frame), cardIntrinsic=\(section.cardView.intrinsicContentSize)"
        )
        XCTAssertFalse(
            section.hasSearchNaturalHeightConstraintForTesting,
            "global search sections use intrinsic height without a required exact-height lock"
        )
        XCTAssertLessThanOrEqual(
            section.frame.height,
            section.intrinsicContentSize.height + 1,
            "a filtered section should stay at its natural height; section=\(section.frame), intrinsic=\(section.intrinsicContentSize), stack=\(section.contentStack.frame), heading=\(section.headingLabel.frame), card=\(section.cardView.frame), gap=\(sectionHeadingToCardGap(in: section))"
        )
    }

    func testToolbarSearchKeepsGlobalResultsAndQueryOnPageChange() throws {
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

        let owner = try XCTUnwrap(window.toolbar?.delegate as? DashboardToolbarController)
        owner.beginSearch()
        let searchField = try XCTUnwrap(
            DashboardSearchToolbarProbe.searchField(in: window.toolbar?.items.last)
        )
        XCTAssertEqual(
            searchField.placeholderString,
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
        XCTAssertEqual(
            visibleSearchableRowTitles(in: composition.currentHostedPageContentForTesting()),
            [tr(.keyDashboardGeneralAndRefreshPagesLanguage)]
        )
        XCTAssertTrue(emptyState(in: composition.currentHostedPageContentForTesting())?.isHidden != false)

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

    func testActiveGlobalSearchSidebarSelectionKeepsSearchRootMountedUntilClear() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-457-search-sidebar.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.setContentSize(NSSize(width: 1000, height: 700))

        composition.applySearchQueryForTesting(
            tr(.keyDashboardGeneralAndRefreshPagesLanguage)
        )
        let searchRoot = composition.currentHostedPageContentForTesting()
        let materializedBeforeSelection = DashboardPageSearchDiagnostics.globalSearchPagesMaterializedCount

        composition.showSection(.menuBar)

        XCTAssertTrue(
            composition.currentHostedPageContentForTesting() === searchRoot,
            "active global search must not replace its result root for a sidebar selection"
        )
        XCTAssertEqual(composition.section, .menuBar)
        XCTAssertEqual(
            DashboardPageSearchDiagnostics.globalSearchPagesMaterializedCount,
            materializedBeforeSelection
        )

        composition.showSection(.about)
        let aboutSearchRoot = composition.currentHostedPageContentForTesting()
        XCTAssertFalse(aboutSearchRoot === searchRoot)
        XCTAssertEqual(composition.section, .about)

        composition.showSection(.general)
        XCTAssertFalse(composition.currentHostedPageContentForTesting() === aboutSearchRoot)
        XCTAssertEqual(composition.section, .general)

        composition.applySearchQueryForTesting("")

        XCTAssertFalse(composition.currentHostedPageContentForTesting() === searchRoot)
        XCTAssertEqual(composition.section, .general)
    }

    func testSearchShowsCrossSectionResultsThenClearsToTheStartingPage() throws {
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
        XCTAssertEqual(composition.section, .general)
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
        XCTAssertEqual(composition.section, .general)
        XCTAssertEqual(composition.searchQueryForTesting, "")
        XCTAssertTrue(emptyState(in: composition.currentHostedPageContentForTesting())?.isHidden != false)
    }

    func testSearchItemStaysOnProviderPagesAndDoesNotUseAccessories() throws {
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true)
        ]
        let controller = DashboardShellTestHarness(
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
                DashboardToolbarController.refreshItemIdentifier,
                DashboardToolbarController.searchItemIdentifier
            ]
        )
        XCTAssertEqual(
            window.toolbar?.items.last?.itemIdentifier,
            DashboardToolbarController.searchItemIdentifier
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

    func testBusinessHiddenRowThatBecomesVisibleDuringSearchRemainsFiltered() {
        let rightClick = SettingsRowView(title: "Right Click")
        let reverseMouseButtons = SettingsRowView(title: "Reverse Mouse Buttons")
        reverseMouseButtons.isHidden = true
        let stack = DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "Behavior", contentViews: [rightClick, reverseMouseButtons])
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
        XCTAssertTrue(reverseMouseButtons.isHidden)
        XCTAssertTrue(DashboardSearchVisibility.isSearchHidden(reverseMouseButtons))

        reverseMouseButtons.isHidden = false
        XCTAssertTrue(reverseMouseButtons.isHidden)
        XCTAssertTrue(DashboardSearchVisibility.isSearchHidden(reverseMouseButtons))

        XCTAssertTrue(
            filter.apply(
                query: "",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertFalse(reverseMouseButtons.isHidden)
    }

    func testLegacySettingsCardSearchCollapseRemeasuresAndRestoresHeight() throws {
        let kept = DashboardSettingsComponents.makeSettingsRow("Keep")
        let filtered = DashboardSettingsComponents.makeSettingsRow("Filter")
        let alsoFiltered = DashboardSettingsComponents.makeSettingsRow("Also Filter")
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Legacy",
            rows: [kept, filtered, alsoFiltered]
        )
        let root = DashboardSettingsComponents.makeSettingsPageContent([section])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = root
        root.frame = window.contentView?.bounds ?? .zero
        root.autoresizingMask = [.width, .height]

        func layout() {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            SettingsRowView.flushPendingWrappingHeightCommits(in: root)
            root.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            root.layoutSubtreeIfNeeded()
        }

        layout()
        let rowsStack = try XCTUnwrap(kept.superview as? NSStackView)
        let card = try XCTUnwrap(rowsStack.superview)
        let expandedHeight = card.frame.height
        XCTAssertGreaterThan(expandedHeight, SettingsRowView.minimumHeight * 2)

        let filter = DashboardPageSearchFilter()
        XCTAssertTrue(
            filter.apply(
                query: "Keep",
                to: root,
                pageTitle: "Legacy",
                mode: .titles
            )
        )
        layout()
        XCTAssertLessThan(card.frame.height, expandedHeight - SettingsRowView.minimumHeight)
        XCTAssertFalse(kept.isHidden)
        XCTAssertTrue(filtered.isHidden || DashboardSearchVisibility.isSearchHidden(filtered))
        XCTAssertTrue(alsoFiltered.isHidden || DashboardSearchVisibility.isSearchHidden(alsoFiltered))

        XCTAssertTrue(
            filter.apply(
                query: "",
                to: root,
                pageTitle: "Legacy",
                mode: .titles
            )
        )
        layout()
        XCTAssertEqual(card.frame.height, expandedHeight, accuracy: 1.0)
        XCTAssertFalse(filtered.isHidden)
        XCTAssertFalse(alsoFiltered.isHidden)
    }

    func testMenuPageRefreshReconcilesActiveSearchForDedicatedProgressRow() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-436-menu-refresh.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()

        let progressSwitch = try XCTUnwrap(
            firstDescendant(of: composition.currentHostedPageContentForTesting()) { view in
                (view as? NSSwitch)?.identifier?.rawValue == AppPreferences.showQuotaProgressBarKey
            } as? NSSwitch
        )
        if progressSwitch.state != .on {
            progressSwitch.state = .on
            _ = NSApp.sendAction(
                try XCTUnwrap(progressSwitch.action),
                to: progressSwitch.target,
                from: progressSwitch
            )
        }

        let query = tr(.keyDashboardMenuPageProgressColorRanges)
        composition.applySearchQueryForTesting(query)
        window.layoutIfNeeded()
        let progressRow = try XCTUnwrap(
            row(containingTitle: query, in: composition.currentHostedPageContentForTesting())
        )
        XCTAssertFalse(progressRow.isHidden)

        progressSwitch.state = .off
        _ = NSApp.sendAction(
            try XCTUnwrap(progressSwitch.action),
            to: progressSwitch.target,
            from: progressSwitch
        )
        window.layoutIfNeeded()
        XCTAssertEqual(composition.searchQueryForTesting, query)
        XCTAssertTrue(progressRow.isHidden)
        XCTAssertFalse(try XCTUnwrap(emptyState(in: composition.currentHostedPageContentForTesting())).isHidden)

        progressSwitch.state = .on
        _ = NSApp.sendAction(
            try XCTUnwrap(progressSwitch.action),
            to: progressSwitch.target,
            from: progressSwitch
        )
        window.layoutIfNeeded()
        XCTAssertEqual(composition.searchQueryForTesting, query)
        XCTAssertFalse(progressRow.isHidden)
        XCTAssertTrue(emptyState(in: composition.currentHostedPageContentForTesting())?.isHidden != false)
    }

    func testMenuBarRefreshReconcilesActiveSearchWhenBusinessVisibilityChanges() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-436-menubar-refresh.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .menuBar))
        window.layoutIfNeeded()

        let reverseTitle = tr(.keyDashboardMenuBarPageReverseMouseButtons)

        func currentRightClickControl() throws -> NSPopUpButton {
            try XCTUnwrap(
                firstDescendant(of: composition.currentHostedPageContentForTesting()) { view in
                    (view as? NSPopUpButton)?.identifier?.rawValue
                        == DashboardMenuBarPage.rightClickActionIdentifier
                } as? NSPopUpButton
            )
        }

        func select(_ action: MenuBarRightClickAction) throws {
            let rightClick = try currentRightClickControl()
            let index = try XCTUnwrap(
                rightClick.itemArray.firstIndex {
                    ($0.representedObject as? String) == action.rawValue
                }
            )
            rightClick.selectItem(at: index)
            _ = NSApp.sendAction(
                try XCTUnwrap(rightClick.action),
                to: rightClick.target,
                from: rightClick
            )
            window.layoutIfNeeded()
        }

        try select(.openMainWindow)
        let normalReverseRow = try XCTUnwrap(
            row(containingTitle: reverseTitle, in: composition.currentHostedPageContentForTesting())
        )
        XCTAssertFalse(normalReverseRow.isHidden)

        composition.applySearchQueryForTesting(reverseTitle)
        window.layoutIfNeeded()
        XCTAssertEqual(composition.searchQueryForTesting, reverseTitle)
        let reverseSearchRow = try XCTUnwrap(
            row(containingTitle: reverseTitle, in: composition.currentHostedPageContentForTesting())
        )
        XCTAssertFalse(reverseSearchRow.isHidden)
        XCTAssertTrue(emptyState(in: composition.currentHostedPageContentForTesting())?.isHidden != false)

        try select(.matchLeftClick)
        XCTAssertEqual(composition.searchQueryForTesting, reverseTitle)
        XCTAssertTrue(reverseSearchRow.isHidden)
        XCTAssertFalse(try XCTUnwrap(emptyState(in: composition.currentHostedPageContentForTesting())).isHidden)

        composition.applySearchQueryForTesting("")
        window.layoutIfNeeded()
        let restoredReverseRow = try XCTUnwrap(
            row(containingTitle: reverseTitle, in: composition.currentHostedPageContentForTesting())
        )
        XCTAssertTrue(restoredReverseRow.isHidden)

        try select(.openMainWindow)
        XCTAssertFalse(restoredReverseRow.isHidden)

        composition.applySearchQueryForTesting(reverseTitle)
        window.layoutIfNeeded()
        XCTAssertEqual(composition.searchQueryForTesting, reverseTitle)
        let secondSearchRow = try XCTUnwrap(
            row(containingTitle: reverseTitle, in: composition.currentHostedPageContentForTesting())
        )
        XCTAssertFalse(secondSearchRow.isHidden)
        XCTAssertTrue(emptyState(in: composition.currentHostedPageContentForTesting())?.isHidden != false)
    }

    func testSearchSeparatorReappearsWhenBusinessHiddenMatchingRowIsRevealed() throws {
        let first = SettingsRowView(title: "Option A")
        let second = SettingsRowView(title: "Option B")
        second.isHidden = true
        let section = SettingsSectionView(title: "Settings", contentViews: [first, second])
        let root = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(filter.apply(query: "Option", to: root, pageTitle: "Settings", mode: .titles))
        let separator = try XCTUnwrap(section.separators.first)
        XCTAssertFalse(first.isHidden)
        XCTAssertTrue(second.isHidden)
        XCTAssertTrue(separator.isHidden)
        XCTAssertTrue(DashboardSearchVisibility.isSearchHidden(separator))

        second.isHidden = false
        XCTAssertFalse(second.isHidden)
        XCTAssertFalse(separator.isHidden)
        XCTAssertFalse(DashboardSearchVisibility.isSearchHidden(separator))
        XCTAssertNotEqual(section.cardView.visibilityPriority(for: separator), .notVisible)
    }

    func testSearchSeparatorConvergesWhenBusinessRowHidesAndStaysHiddenAfterClear() throws {
        let first = SettingsRowView(title: "Option A")
        let second = SettingsRowView(title: "Option B")
        let section = SettingsSectionView(title: "Settings", contentViews: [first, second])
        let root = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()
        let query = "Option"

        XCTAssertTrue(filter.apply(query: query, to: root, pageTitle: "Settings", mode: .titles))
        let separator = try XCTUnwrap(section.separators.first)
        XCTAssertFalse(separator.isHidden)

        second.isHidden = true
        XCTAssertTrue(filter.apply(query: query, to: root, pageTitle: "Settings", mode: .titles))
        XCTAssertFalse(first.isHidden)
        XCTAssertTrue(second.isHidden)
        XCTAssertTrue(separator.isHidden)

        XCTAssertTrue(filter.apply(query: "", to: root, pageTitle: "Settings", mode: .titles))
        XCTAssertFalse(first.isHidden)
        XCTAssertTrue(second.isHidden)
        XCTAssertTrue(separator.isHidden)
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
            visibleSearchableRowTitles(in: composition.currentHostedPageContentForTesting())
                .contains(tr(.keyDashboardMenuBarPageReverseMouseButtons)),
            "business-hidden settings must remain excluded from global results"
        )
        XCTAssertFalse(try XCTUnwrap(emptyState(in: composition.currentHostedPageContentForTesting())).isHidden)

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

    func testBusinessHiddenNonMatchingRowStaysSearchHiddenWhenBusinessRevealsItDuringActiveQuery() {
        let rightClick = SettingsRowView(title: "Right Click")
        let reverseMouseButtons = SettingsRowView(title: "Reverse Mouse Buttons")
        reverseMouseButtons.isHidden = true
        let section = SettingsSectionView(
            title: "Behavior",
            contentViews: [rightClick, reverseMouseButtons]
        )
        let stack = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(
            filter.apply(
                query: "Right Click",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertFalse(isCollapsedForSearch(rightClick))
        XCTAssertTrue(isCollapsedForSearch(reverseMouseButtons))
        XCTAssertTrue(DashboardSearchVisibility.isSearchHidden(reverseMouseButtons))

        reverseMouseButtons.isHidden = false

        XCTAssertTrue(DashboardSearchVisibility.isSearchHidden(reverseMouseButtons))
        XCTAssertTrue(isCollapsedForSearch(reverseMouseButtons))
        XCTAssertTrue(reverseMouseButtons.isHidden)
        XCTAssertFalse(isCollapsedForSearch(rightClick))

        XCTAssertTrue(
            filter.apply(
                query: "",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertFalse(DashboardSearchVisibility.isSearchHidden(reverseMouseButtons))
        XCTAssertFalse(isCollapsedForSearch(reverseMouseButtons))
        XCTAssertFalse(reverseMouseButtons.isHidden)
    }

    func testBusinessHiddenMatchingRowBecomesVisibleResultWhenBusinessRevealsItDuringActiveQuery() {
        let rightClick = SettingsRowView(title: "Right Click")
        let reverseMouseButtons = SettingsRowView(title: "Reverse Mouse Buttons")
        reverseMouseButtons.isHidden = true
        let section = SettingsSectionView(
            title: "Behavior",
            contentViews: [rightClick, reverseMouseButtons]
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
        XCTAssertTrue(reverseMouseButtons.isHidden)
        XCTAssertTrue(isCollapsedForSearch(section))
        XCTAssertFalse(try XCTUnwrap(emptyState(in: stack)).isHidden)
        XCTAssertFalse(
            filter.pageContainsMatch(
                query: "Reverse Mouse Buttons",
                in: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )

        reverseMouseButtons.isHidden = false

        XCTAssertFalse(DashboardSearchVisibility.isSearchHidden(reverseMouseButtons))
        XCTAssertFalse(isCollapsedForSearch(reverseMouseButtons))
        XCTAssertFalse(reverseMouseButtons.isHidden)
        XCTAssertFalse(isCollapsedForSearch(section))
        XCTAssertTrue(emptyState(in: stack)?.isHidden != false)
        XCTAssertTrue(
            filter.pageContainsMatch(
                query: "Reverse Mouse Buttons",
                in: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertTrue(isCollapsedForSearch(rightClick))
    }

    func testSearchAndBusinessVisibilityChangesDoNotLeaveLeadingTrailingOrDoubleSeparators() {
        let first = SettingsRowView(title: "Right Click")
        let middle = SettingsRowView(title: "Reverse Mouse Buttons")
        let last = SettingsRowView(title: "Layout")
        middle.isHidden = true
        let section = SettingsSectionView(
            title: "Behavior",
            contentViews: [first, middle, last]
        )
        let stack = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(
            filter.apply(
                query: "Right Click",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        assertSectionSeparatorsAreValid(section)

        middle.isHidden = false
        XCTAssertTrue(isCollapsedForSearch(middle))
        assertSectionSeparatorsAreValid(section)

        last.isHidden = true
        XCTAssertFalse(
            filter.apply(
                query: "Layout",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertFalse(try XCTUnwrap(emptyState(in: stack)).isHidden)
        assertSectionSeparatorsAreValid(section)

        last.isHidden = false
        XCTAssertFalse(isCollapsedForSearch(last))
        XCTAssertTrue(emptyState(in: stack)?.isHidden != false)
        assertSectionSeparatorsAreValid(section)

        XCTAssertTrue(
            filter.apply(
                query: "",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertFalse(first.isHidden)
        XCTAssertFalse(middle.isHidden)
        XCTAssertFalse(last.isHidden)
        assertSectionSeparatorsAreValid(section)
    }

    func testSearchRestoreDoesNotOverwriteCustomStackVisibilityPriority() {
        let kept = SettingsRowView(title: "Right Click")
        let filtered = SettingsRowView(title: "Reverse Mouse Buttons")
        let section = SettingsSectionView(
            title: "Behavior",
            contentViews: [kept, filtered]
        )
        let customPriority = NSStackView.VisibilityPriority(rawValue: 250)
        section.cardView.setVisibilityPriority(customPriority, for: filtered)
        XCTAssertEqual(section.cardView.visibilityPriority(for: filtered), customPriority)

        let stack = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()
        XCTAssertTrue(
            filter.apply(
                query: "Right Click",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertEqual(section.cardView.visibilityPriority(for: filtered), .notVisible)

        XCTAssertTrue(
            filter.apply(
                query: "",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertEqual(section.cardView.visibilityPriority(for: filtered), customPriority)
        XCTAssertEqual(section.cardView.visibilityPriority(for: kept), .mustHold)
    }

    func testMenuBarSearchableRowsUseDefaultStackVisibilityPriority() throws {
        let suiteName = "DashboardPageSearchTests.VisibilityPriority.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let page = DashboardMenuBarPage().make(.init(
            preferences: AppPreferences(defaults: defaults),
            snapshot: Snapshot.official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay()
        ))
        let rows = searchableRows(in: page)
        XCTAssertFalse(rows.isEmpty)
        var visibleRowCount = 0
        for row in rows {
            guard let stack = row.superview as? NSStackView,
                  stack.arrangedSubviews.contains(row) else {
                continue
            }
            if row.isHidden || DashboardSearchVisibility.isBusinessHidden(row) {
                continue
            }
            visibleRowCount += 1
            XCTAssertEqual(
                stack.visibilityPriority(for: row),
                .mustHold,
                "visible production searchable rows keep default stack visibility priority"
            )
        }
        XCTAssertGreaterThan(visibleRowCount, 0)
    }

    func testSearchStillFiltersLegacyRowAfterBusinessIdentifierOverwrite() {
        let matching = DashboardSettingsComponents.makeSettingsRow("Right Click")
        let hiddenBySearch = DashboardSettingsComponents.makeSettingsRow("Reverse Mouse Buttons")
        hiddenBySearch.identifier = NSUserInterfaceItemIdentifier("menuBar.animationFallbackWarningRow")
        XCTAssertNotEqual(hiddenBySearch.identifier, DashboardPageSearch.rowIdentifier)
        XCTAssertTrue(DashboardPageSearch.isSearchableRow(hiddenBySearch))

        let section = DashboardSettingsComponents.makeSettingsSection(
            "Behavior",
            rows: [matching, hiddenBySearch]
        )
        let stack = DashboardSettingsComponents.makeSettingsPageContent([section])
        let filter = DashboardPageSearchFilter()

        XCTAssertTrue(
            filter.apply(
                query: "Right Click",
                to: stack,
                pageTitle: "Menu Bar",
                mode: .titles
            )
        )
        XCTAssertFalse(isCollapsedForSearch(matching))
        XCTAssertTrue(isCollapsedForSearch(hiddenBySearch))
    }

    func testSearchVisibilityMutationRestoresFlagWhenNested() {
        DashboardSearchVisibility.isMutatingSearchVisibility = false
        DashboardSearchVisibility.withSearchVisibilityMutation {
            XCTAssertTrue(DashboardSearchVisibility.isMutatingSearchVisibility)
            DashboardSearchVisibility.withSearchVisibilityMutation {
                XCTAssertTrue(DashboardSearchVisibility.isMutatingSearchVisibility)
            }
            XCTAssertTrue(DashboardSearchVisibility.isMutatingSearchVisibility)
        }
        XCTAssertFalse(DashboardSearchVisibility.isMutatingSearchVisibility)
    }
}

@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
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

private func searchableRows(in root: NSView) -> [NSView] {
    var rows: [NSView] = []
    if DashboardPageSearch.isSearchableRow(root) {
        rows.append(root)
    }
    for child in root.subviews {
        rows.append(contentsOf: searchableRows(in: child))
    }
    return rows
}

private func visibleSearchableRowTitles(in root: NSView) -> [String] {
    func visibleRows(in view: NSView) -> [String] {
        guard view.identifier != DashboardPageSearch.emptyStateIdentifier,
              !isCollapsedForSearch(view) else { return [] }
        var titles: [String] = []
        if let row = view as? SettingsRowView {
            titles.append(row.titleLabel.stringValue)
        }
        for child in view.subviews {
            titles.append(contentsOf: visibleRows(in: child))
        }
        return titles
    }
    return visibleRows(in: root).sorted()
}

private func sectionHeadingToCardGap(in section: SettingsSectionView) -> CGFloat {
    let heading = section.headingLabel.convert(section.headingLabel.bounds, to: section)
    let card = section.cardView.convert(section.cardView.bounds, to: section)
    if heading.minY >= card.maxY {
        return heading.minY - card.maxY
    }
    if card.minY >= heading.maxY {
        return card.minY - heading.maxY
    }
    return 0
}

private func assertSectionSeparatorsAreValid(_ section: SettingsSectionView) {
    let visible = section.cardView.arrangedSubviews.filter { view in
        if view is NSBox {
            return !view.isHidden && !DashboardSearchVisibility.isSearchHidden(view)
        }
        return !isCollapsedForSearch(view)
    }
    if visible.isEmpty {
        XCTAssertTrue(isCollapsedForSearch(section))
        return
    }
    XCTAssertFalse(visible.first is NSBox, "leading separator")
    XCTAssertFalse(visible.last is NSBox, "trailing separator")
    for index in 1..<visible.count {
        XCTAssertFalse(
            visible[index] is NSBox && visible[index - 1] is NSBox,
            "double separator"
        )
    }
}

private func row(containingTitle title: String, in root: NSView) -> NSView? {
    if let row = root as? SettingsRowView, row.titleLabel.stringValue == title {
        return row
    }
    if DashboardPageSearch.isSearchableRow(root),
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
