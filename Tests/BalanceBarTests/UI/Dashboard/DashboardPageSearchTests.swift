import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardPageSearchTests: XCTestCase {
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
            XCTAssertFalse(controller.isSearchExpanded)
            let slot = try XCTUnwrap(window.toolbar?.items.last as? NSSearchToolbarItem)
            XCTAssertTrue(DashboardSearchToolbarProbe.isCollapsedButtonRepresentation(slot))
            XCTAssertLessThanOrEqual(slot.searchField.frame.width, 40)
            XCTAssertEqual(slot.toolTip, tr(.keyDashboardSearchPlaceholder))
            let clickPoint = slot.searchField.convert(
                NSPoint(x: slot.searchField.bounds.midX, y: slot.searchField.bounds.midY),
                to: nil
            )
            let click = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: clickPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
            window.sendEvent(click)
            await drainMainQueue()
            XCTAssertTrue(controller.isSearchExpanded)
            XCTAssertTrue(window.toolbar?.items.last === slot)
            let field = slot.searchField
            window.layoutIfNeeded()
            window.displayIfNeeded()
            XCTAssertFalse(field.isHidden)
            XCTAssertGreaterThanOrEqual(field.frame.width, 100)
            field.stringValue = "Language"
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertEqual(controller.searchQuery, "Language")
            controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
            await drainMainQueue()
            XCTAssertTrue(controller.isSearchExpanded)
            XCTAssertTrue(window.toolbar?.items.last === slot)
            XCTAssertEqual(controller.searchQuery, "Language")
            let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
            XCTAssertNotNil(cell.cancelButtonCell)
            field.stringValue = ""
            controller.searchFieldDidEndSearching(field)
            await drainMainQueue()
            XCTAssertEqual(controller.searchQuery, "")
            XCTAssertFalse(controller.isSearchExpanded)
            XCTAssertTrue(
                DashboardSearchToolbarProbe.isCollapsedButtonRepresentation(window.toolbar?.items.last)
            )
            XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier), DashboardToolbarController.defaultItemIdentifiers)
        }
        XCTAssertEqual(queries, ["Language", "", "Language", ""])
    }

    func testDeletingLastCharacterStaysExpandedUntilFocusLeaves() async throws {
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
        controller.setQuery("a")
        let field = try XCTUnwrap(
            DashboardSearchToolbarProbe.searchField(in: window.toolbar?.items.last)
        )
        field.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(controller.searchQuery, "")
        XCTAssertTrue(controller.isSearchExpanded)
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        await drainMainQueue()
        XCTAssertFalse(controller.isSearchExpanded)
        XCTAssertTrue(
            DashboardSearchToolbarProbe.isCollapsedButtonRepresentation(window.toolbar?.items.last)
        )
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
        XCTAssertTrue(controller.isSearchExpanded)
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
        XCTAssertTrue(controller.isSearchExpanded)
        editor.unmarkText()
        XCTAssertTrue(controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(controller.searchQuery, "")
        XCTAssertFalse(controller.isSearchExpanded)
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
        XCTAssertTrue(owner.isSearchExpanded)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(owner.searchQuery, query)
        editor.unmarkText()
        composition.showSection(.menuBar)
        XCTAssertTrue(owner.isSearchExpanded)
        owner.endSearch()
        XCTAssertEqual(composition.section, .menuBar)
        XCTAssertEqual(composition.searchQueryForTesting, "")
        XCTAssertTrue(emptyState(in: composition.currentHostedPageContentForTesting())?.isHidden != false)
        XCTAssertTrue(
            DashboardSearchToolbarProbe.isCollapsedButtonRepresentation(window.toolbar?.items.last)
        )
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
        owners[1].endSearch()
        XCTAssertEqual(owners[0].searchQuery, "Language")
        XCTAssertTrue(windows[0].toolbar?.items.last === firstItem)
        XCTAssertTrue(
            DashboardSearchToolbarProbe.isCollapsedButtonRepresentation(windows[1].toolbar?.items.last)
        )
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
                DashboardToolbarController.searchItemIdentifier
            ]
        )
        XCTAssertEqual(
            window.toolbar?.items.last?.itemIdentifier,
            DashboardToolbarController.searchItemIdentifier
        )
        XCTAssertTrue(
            DashboardSearchToolbarProbe.isCollapsedButtonRepresentation(window.toolbar?.items.last)
        )
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

        let rightClick = try XCTUnwrap(
            firstDescendant(of: composition.currentHostedPageContentForTesting()) { view in
                (view as? NSPopUpButton)?.identifier?.rawValue
                    == DashboardMenuBarPage.rightClickActionIdentifier
            } as? NSPopUpButton
        )
        let reverseTitle = tr(.keyDashboardMenuBarPageReverseMouseButtons)
        let reverseRow = try XCTUnwrap(
            row(containingTitle: reverseTitle, in: composition.currentHostedPageContentForTesting())
        )

        func select(_ action: MenuBarRightClickAction) throws {
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
        XCTAssertFalse(reverseRow.isHidden)

        composition.applySearchQueryForTesting(reverseTitle)
        window.layoutIfNeeded()
        XCTAssertEqual(composition.searchQueryForTesting, reverseTitle)
        XCTAssertFalse(reverseRow.isHidden)
        XCTAssertTrue(emptyState(in: composition.currentHostedPageContentForTesting())?.isHidden != false)

        try select(.matchLeftClick)
        XCTAssertEqual(composition.searchQueryForTesting, reverseTitle)
        XCTAssertTrue(reverseRow.isHidden)
        XCTAssertFalse(try XCTUnwrap(emptyState(in: composition.currentHostedPageContentForTesting())).isHidden)

        composition.applySearchQueryForTesting("")
        window.layoutIfNeeded()
        XCTAssertTrue(reverseRow.isHidden)

        try select(.openMainWindow)
        XCTAssertFalse(reverseRow.isHidden)

        composition.applySearchQueryForTesting(reverseTitle)
        window.layoutIfNeeded()
        XCTAssertEqual(composition.searchQueryForTesting, reverseTitle)
        XCTAssertFalse(reverseRow.isHidden)
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
