import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardKeyboardNavigationTests: XCTestCase {
    func testProductionWindowAutorecalculatesKeyViewLoop() throws {
        let window = DashboardWindowController.makeUnpresentedWindow(initialSection: .general)
        defer { window.close() }
        XCTAssertTrue(window.autorecalculatesKeyViewLoop)

        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let windowSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardWindowController.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(windowSource.contains("autorecalculatesKeyViewLoop = true"))
        XCTAssertFalse(windowSource.contains("nextKeyView ="))
        XCTAssertFalse(windowSource.contains("func replacePage("))
    }

    func testReplacingPageRemovesOldControlsFromWindow() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-445-page-replace.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let composition = appDelegate.dashboardCompositionForTesting
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        XCTAssertTrue(window.autorecalculatesKeyViewLoop)

        let generalPage = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        let generalSwitch = try XCTUnwrap(descendant(in: generalPage, as: NSSwitch.self))
        XCTAssertNotNil(generalSwitch.superview)
        XCTAssertTrue(generalSwitch.window === window)

        composition.showSection(.about)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        XCTAssertNil(generalPage.superview)
        XCTAssertNil(generalSwitch.window)
        let aboutPage = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        let githubButton = try XCTUnwrap(
            descendant(in: aboutPage, as: DashboardAboutGitHubButton.self)
        )
        XCTAssertTrue(githubButton.window === window)
        XCTAssertEqual(githubButton.accessibilityRole(), .button)
        XCTAssertFalse(githubButton.accessibilityLabel()?.isEmpty ?? true)

        composition.showSection(.general)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let restoredGeneral = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        XCTAssertNotNil(descendant(in: restoredGeneral, as: NSSwitch.self))
        XCTAssertNil(aboutPage.superview)
        XCTAssertNil(githubButton.window)
    }

    func testSearchHideAndRestoreUpdatesVisibleStandardControls() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-445-search-loop.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let composition = appDelegate.dashboardCompositionForTesting
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let page = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        let silentSwitch = try XCTUnwrap(
            descendant(in: page, as: NSSwitch.self) {
                $0.identifier?.rawValue == AppPreferences.silentLaunchKey
            }
        )
        let languagePopup = try XCTUnwrap(
            descendant(in: page, as: NSPopUpButton.self) {
                $0.identifier?.rawValue == AppLanguage.preferenceKey
            }
        )
        let silentRow = try XCTUnwrap(SettingsRowView.enclosing(silentSwitch))

        composition.applySearchQueryForTesting(tr(.keyDashboardGeneralAndRefreshPagesLanguage))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        XCTAssertTrue(DashboardSearchVisibility.isCollapsedForSearchLayout(silentRow))
        XCTAssertNotNil(languagePopup.window)
        XCTAssertFalse(DashboardSearchVisibility.isCollapsedForSearchLayout(languagePopup))

        composition.applySearchQueryForTesting("")
        window.layoutIfNeeded()
        window.displayIfNeeded()

        XCTAssertFalse(DashboardSearchVisibility.isCollapsedForSearchLayout(silentRow))
        XCTAssertNotNil(silentSwitch.window)
        XCTAssertNotNil(languagePopup.window)
    }

    func testHidingEditedNumericFieldResignsFieldAndFieldEditor() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-445-numeric-resign.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let composition = appDelegate.dashboardCompositionForTesting
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let page = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        let field = try XCTUnwrap(
            descendant(in: page, as: NSTextField.self) {
                $0.identifier?.rawValue == AppPreferences.balanceDisplayThresholdKey && $0.isEditable
            }
        )
        let row = try XCTUnwrap(SettingsRowView.enclosing(field))
        XCTAssertTrue(field.window === window)

        if window.makeFirstResponder(field) {
            XCTAssertTrue(
                window.firstResponder === field
                    || (window.firstResponder as? NSTextView)?.delegate as AnyObject? === field
            )
            composition.applySearchQueryForTesting(tr(.keyDashboardMenuPageStatusLinks))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            XCTAssertTrue(DashboardSearchVisibility.isCollapsedForSearchLayout(row))
            XCTAssertFalse(window.firstResponder === field)
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                XCTAssertFalse((editor.delegate as AnyObject?) === field)
            }
            XCTAssertNil(field.currentEditor())
        } else {
            composition.applySearchQueryForTesting(tr(.keyDashboardMenuPageStatusLinks))
            window.layoutIfNeeded()
            XCTAssertTrue(DashboardSearchVisibility.isCollapsedForSearchLayout(row))
        }
    }

    func testSearchQueryDoesNotResignToolbarSearchField() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-445-search-field.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let composition = appDelegate.dashboardCompositionForTesting
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let owner = try XCTUnwrap(window.toolbar?.delegate as? DashboardToolbarController)
        owner.beginSearch()
        let searchField = try XCTUnwrap(
            DashboardSearchToolbarProbe.searchField(in: window.toolbar?.items.last)
        )
        if window.makeFirstResponder(searchField) {
            composition.applySearchQueryForTesting(tr(.keyDashboardGeneralAndRefreshPagesLanguage))
            window.layoutIfNeeded()
            let first = window.firstResponder
            XCTAssertTrue(
                first === searchField
                    || (first as? NSTextView)?.delegate as AnyObject? === searchField,
                "typing a query must not resign the toolbar search field"
            )
        }
    }

    func testCommandFExpandsTheSingleSearchSlotAndEscapeClosesIt() throws {
        let controller = DashboardToolbarController()
        let window = DashboardSearchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            controller.detach()
            window.close()
        }
        ApplicationWindowPresentation.presentInBackground(window)
        controller.install(on: window)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        ))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertTrue(controller.isSearchExpanded)
        controller.setQuery("Language")
        let slot = try XCTUnwrap(window.toolbar?.items.last)
        let field = try XCTUnwrap(DashboardSearchToolbarProbe.searchField(in: slot))
        if field.currentEditor() == nil {
            _ = window.makeFirstResponder(field)
        }
        window.cancelOperation(nil)
        XCTAssertEqual(controller.searchQuery, "")
        XCTAssertFalse(controller.isSearchExpanded)
        XCTAssertTrue(
            DashboardSearchToolbarProbe.isCollapsedButtonRepresentation(window.toolbar?.items.last)
        )
    }

    func testSidebarGroupRowsAreNotSelectableAndArrowsSkipThem() throws {
        var pageShows = 0
        let controller = DashboardShellTestHarness(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in
                    pageShows += 1
                    return DashboardHostedPageViewController()
                },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        let appearance = try XCTUnwrap(sourceList.roots.first { $0.group == .appearance })
        XCTAssertFalse(sourceList.outlineView(outline, shouldSelectItem: appearance))
        let system = try XCTUnwrap(sourceList.roots.first { $0.group == .system })
        XCTAssertFalse(sourceList.outlineView(outline, shouldSelectItem: system))
        let generalNode = try XCTUnwrap(sourceList.node(for: .general))
        XCTAssertTrue(sourceList.outlineView(outline, shouldSelectItem: generalNode))

        XCTAssertTrue(window.makeFirstResponder(outline))
        sourceList.applySelection(.general)
        let afterGeneral = pageShows

        outline.moveDown(nil)
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)
        XCTAssertEqual(controller.section, .menuBar)

        outline.moveDown(nil)
        XCTAssertEqual(sourceList.selectedSection(), .menu)
        XCTAssertEqual(controller.section, .menu)
        XCTAssertEqual(pageShows, afterGeneral + 2)
    }

    func testRebuildDropsOldPageControlsAndRebindsNewTitleUIElement() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-445-rebuild-loop.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let composition = appDelegate.dashboardCompositionForTesting
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let originalPage = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        let originalSwitch = try XCTUnwrap(
            descendant(in: originalPage, as: NSSwitch.self) {
                $0.identifier?.rawValue == AppPreferences.silentLaunchKey
            }
        )
        let originalTitle = originalSwitch.accessibilityTitleUIElement() as AnyObject?

        composition.rebuild()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        XCTAssertNil(originalPage.superview)
        XCTAssertNil(originalSwitch.window)
        let restoredPage = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        let restoredSwitch = try XCTUnwrap(
            descendant(in: restoredPage, as: NSSwitch.self) {
                $0.identifier?.rawValue == AppPreferences.silentLaunchKey
            }
        )
        XCTAssertTrue(restoredSwitch.window === window)
        XCTAssertIdentical(
            restoredSwitch.accessibilityTitleUIElement() as AnyObject?,
            SettingsRowView.enclosing(restoredSwitch)?.titleLabel
        )
        XCTAssertFalse(
            (restoredSwitch.accessibilityTitleUIElement() as AnyObject?) === originalTitle
        )
        XCTAssertTrue(window.autorecalculatesKeyViewLoop)
    }

    func testSearchResignChecksUnreachableBeforeEndingEditing() throws {
        let body = try functionBody(
            named: "static func resignUnreachableFirstResponder",
            in: "Sources/UI/Dashboard/DashboardWindowController.swift",
            until: "private static func isPreservedNavigationSurface"
        )
        let unreachable = try XCTUnwrap(body.range(of: "isUnreachable("))
        let endEditing = try XCTUnwrap(body.range(of: "endEditing("))
        XCTAssertLessThan(
            unreachable.lowerBound,
            endEditing.lowerBound,
            "Search refresh must not end editing until the first responder is unreachable"
        )
    }

    func testMenuBarSnapshotRefreshDoesNotUnconditionallyRecalculateKeyViewLoop() throws {
        let refreshBody = try functionBody(
            named: "func refreshMenuBarPage(snapshot: Snapshot)",
            in: "Sources/UI/Dashboard/DashboardCompositionController.swift",
            until: "func refreshMenuPage()"
        )
        XCTAssertTrue(refreshBody.contains("applyMountedPageSearch()"))
        XCTAssertFalse(
            refreshBody.contains("DashboardKeyViewLoop.invalidate"),
            "Menu Bar snapshot refresh must not recalc the key-view loop on every preview update"
        )

        let warningBody = try functionBody(
            named: "func updateWarnings(",
            in: "Sources/UI/Dashboard/Pages/Preferences/DashboardMenuBarPreviewSection.swift",
            until: "func updatePreviewSeparators()"
        )
        XCTAssertTrue(warningBody.contains("DashboardKeyViewLoop.invalidate"))
    }

    func testReapplyingSearchKeepsEditingAVisibleNumericField() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-445-visible-field.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let composition = appDelegate.dashboardCompositionForTesting
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let page = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        let field = try XCTUnwrap(
            descendant(in: page, as: NSTextField.self) {
                $0.identifier?.rawValue == AppPreferences.balanceDisplayThresholdKey && $0.isEditable
            }
        )
        let row = try XCTUnwrap(SettingsRowView.enclosing(field))
        composition.applySearchQueryForTesting(tr(.keyDashboardMenuPageLowBalanceDisplayThreshold))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        XCTAssertFalse(DashboardSearchVisibility.isCollapsedForSearchLayout(row))
        XCTAssertTrue(field.window === window)

        if window.makeFirstResponder(field) {
            XCTAssertTrue(
                window.firstResponder === field
                    || (window.firstResponder as? NSTextView)?.delegate as AnyObject? === field
            )
            DashboardKeyViewLoop.resignUnreachableFirstResponder(window)
            XCTAssertTrue(
                window.firstResponder === field
                    || (window.firstResponder as? NSTextView)?.delegate as AnyObject? === field,
                "a still-visible field must keep editing across Search refresh"
            )
            composition.refreshMountedPage(snapshot: .placeholder, refreshDate: nil, revision: 1)
            window.layoutIfNeeded()
            XCTAssertFalse(DashboardSearchVisibility.isCollapsedForSearchLayout(row))
            XCTAssertTrue(
                window.firstResponder === field
                    || (window.firstResponder as? NSTextView)?.delegate as AnyObject? === field,
                "quota snapshot refresh must not end editing on a visible Search match"
            )
        } else {
            composition.refreshMountedPage(snapshot: .placeholder, refreshDate: nil, revision: 1)
            window.layoutIfNeeded()
            XCTAssertFalse(DashboardSearchVisibility.isCollapsedForSearchLayout(row))
            XCTAssertTrue(field.window === window)
        }
    }

    private func functionBody(
        named marker: String,
        in relativePath: String,
        until terminator: String
    ) throws -> String {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: marker))
        let rest = start.lowerBound..<source.endIndex
        let end = source.range(of: terminator, range: rest)?.lowerBound ?? source.endIndex
        return String(source[start.lowerBound..<end])
    }

    private func descendant<T: NSView>(
        in view: NSView,
        as type: T.Type,
        where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = view as? T, predicate(match) {
            return match
        }
        for child in view.subviews {
            if let match = descendant(in: child, as: type, where: predicate) {
                return match
            }
        }
        return nil
    }
}
