import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardWindowControllerTests: XCTestCase {
    func testGlassEffectFactoryMatchesRuntimeAvailability() throws {
        let contentView = NSView()
        let glassView = makeDashboardGlassEffectView(contentView: contentView, cornerRadius: 12)

        if #available(macOS 26.0, *) {
            let glassViewClass: AnyClass = try XCTUnwrap(NSClassFromString("NSGlassEffectView"))
            let resolvedView = try XCTUnwrap(glassView)
            XCTAssertTrue(resolvedView.isKind(of: glassViewClass))
            XCTAssertTrue(resolvedView.value(forKey: "contentView") as? NSView === contentView)
        } else {
            XCTAssertNil(glassView)
        }
    }

    func testWindowDisablesNativeZoomButStaysResizable() throws {
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
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
        XCTAssertFalse(window.standardWindowButton(.zoomButton)?.isEnabled ?? true)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
    }

    func testGeneralNavigationShowsAndHidesUpdateBadgeWithUpdateState() throws {
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer { controller.teardown() }

        _ = NSApplication.shared
        controller.setShowsUpdateAvailableBadge(true)
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        func findBadge(in view: NSView) -> DashboardUpdateBadgeView? {
            for child in view.subviews {
                if let badge = child as? DashboardUpdateBadgeView { return badge }
                if let badge = findBadge(in: child) { return badge }
            }
            return nil
        }
        let badge = try XCTUnwrap(findBadge(in: try XCTUnwrap(window.contentView)))
        let row = try XCTUnwrap(badge.superview as? DashboardNavigationRowView)
        let titleLabel = try XCTUnwrap(row.titleLabel)

        XCTAssertFalse(badge.isHidden)
        XCTAssertGreaterThan(badge.frame.minX, titleLabel.frame.maxX)
        XCTAssertLessThanOrEqual(badge.frame.maxX, row.bounds.maxX)

        controller.setShowsUpdateAvailableBadge(false)
        XCTAssertTrue(badge.isHidden)
    }

    func testMenuBarSettingsFittingWidthFollowsLocalization() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        var fittingWidths: [AppLanguage: CGFloat] = [:]
        for language in [
            AppLanguage.simplifiedChinese,
            .english,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese
        ] {
            AppLanguage.selected = language
            let appDelegate = AppDelegate(
                repository: CCSwitchRepository(
                    databaseURL: URL(fileURLWithPath: "/nonexistent/issue-165-\(language.rawValue).db")
                )
            )
            defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }

            let window = try XCTUnwrap(
                appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menuBar)
            )
            window.setContentSize(NSSize(width: 800, height: 540))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let page = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.contentHost.subviews.first)
            fittingWidths[language] = page.fittingSize.width
        }

        let simplifiedChineseFittingWidth = try XCTUnwrap(fittingWidths[.simplifiedChinese])
        let englishFittingWidth = try XCTUnwrap(fittingWidths[.english])
        let japaneseFittingWidth = try XCTUnwrap(fittingWidths[.japanese])
        XCTAssertGreaterThan(
            englishFittingWidth,
            simplifiedChineseFittingWidth + 1,
            "English should retain enough fitting width for its localized copy"
        )
        XCTAssertGreaterThan(
            japaneseFittingWidth,
            simplifiedChineseFittingWidth + 1,
            "Japanese should retain enough fitting width for its localized copy"
        )
    }

    func testWindowZoomStateUsesTargetFrameAndRestoresRepeatedly() {
        let normalFrame = NSRect(x: 120, y: 180, width: 880, height: 620)
        let primaryVisibleFrame = NSRect(x: 0, y: 25, width: 1_440, height: 875)
        let secondaryVisibleFrame = NSRect(x: 1_440, y: 25, width: 1_920, height: 1_055)
        var state = DashboardWindowZoomState()

        XCTAssertEqual(
            state.toggle(currentFrame: normalFrame, targetFrame: primaryVisibleFrame),
            primaryVisibleFrame
        )
        XCTAssertTrue(state.isZoomed)
        XCTAssertEqual(
            state.toggle(currentFrame: primaryVisibleFrame, targetFrame: secondaryVisibleFrame),
            normalFrame
        )
        XCTAssertFalse(state.isZoomed)

        XCTAssertEqual(
            state.toggle(currentFrame: normalFrame, targetFrame: secondaryVisibleFrame),
            secondaryVisibleFrame
        )
        XCTAssertEqual(state.toggle(currentFrame: secondaryVisibleFrame, targetFrame: primaryVisibleFrame), normalFrame)
        XCTAssertFalse(state.isZoomed)
    }

    func testWindowZoomStateDoesNothingWithoutAScreenAndCanReset() {
        let normalFrame = NSRect(x: 120, y: 180, width: 880, height: 620)
        var state = DashboardWindowZoomState()

        XCTAssertNil(state.toggle(currentFrame: normalFrame, targetFrame: nil))
        XCTAssertFalse(state.isZoomed)
        XCTAssertNil(state.toggle(currentFrame: normalFrame, targetFrame: .zero))
        XCTAssertFalse(state.isZoomed)

        let visibleFrame = NSRect(x: 0, y: 25, width: 1_440, height: 875)
        XCTAssertEqual(state.toggle(currentFrame: normalFrame, targetFrame: visibleFrame), visibleFrame)
        XCTAssertTrue(state.isZoomed)
        state.reset()
        XCTAssertFalse(state.isZoomed)
    }

    func testRepeatedStartAndOpenKeepOneObserverMonitorAndWindow() {
        var shownPageCount = 0
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
                providerChoices: { choices },
                prepareForPageReplacement: {},
                didShowPage: { shownPageCount += 1 },
                didClose: {},
                didResize: {}
            )
        )

        controller.start()
        controller.start()
        controller.open()
        let firstWindow = controller.window
        controller.open()
        firstWindow?.close()
        controller.open()

        XCTAssertNotNil(firstWindow)
        XCTAssertTrue(controller.window === firstWindow)
        XCTAssertEqual(controller.windowCreationCount, 1)
        XCTAssertEqual(controller.appearanceObserverInstallCount, 1)
        XCTAssertEqual(controller.mouseMonitorInstallCount, 1)
        XCTAssertEqual(shownPageCount, 1)

        controller.teardown()
        controller.teardown()
    }

    func testNavigationAndProviderSelectionSurviveShellRebuild() {
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        var preparedPageCount = 0
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
                providerChoices: { choices },
                prepareForPageReplacement: { preparedPageCount += 1 },
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )

        controller.open()
        controller.showSection(.menu)
        XCTAssertEqual(controller.section, .menu)
        XCTAssertNil(controller.selectedProviderID)

        controller.showProvider("other")
        XCTAssertEqual(controller.selectedProviderID, "other")
        controller.rebuild()

        XCTAssertEqual(controller.selectedProviderID, "other")
        XCTAssertEqual(controller.section, .menu)
        XCTAssertGreaterThanOrEqual(preparedPageCount, 3)
        XCTAssertEqual(controller.windowCreationCount, 1)
        XCTAssertEqual(controller.mouseMonitorInstallCount, 1)

        controller.teardown()
    }

    func testTeardownIsIdempotentAndStopsWindowDelegateOwnership() {
        var closeCount = 0
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: { closeCount += 1 },
                didResize: {}
            )
        )

        controller.open()
        controller.teardown()
        controller.teardown()

        XCTAssertNil(controller.window)
        XCTAssertEqual(closeCount, 0)
    }
}

@MainActor
final class DashboardProductionPathRegressionTests: XCTestCase {
    func testMenuPageHidesStatusLinksEditorWhenMenuDisplayIsDisabled() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }
        defaults.set(false, forKey: "showStatusMenu")
        defaults.removeObject(forKey: "statusLinks")

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let page = appDelegate.dashboardCompositionForTesting.makePageForTesting(.menu)

        let editor = findStatusLinksEditor(in: page)
        XCTAssertNotNil(editor, "The Status Links editor stays in the page so it can animate in place")
        XCTAssertFalse(editor?.isVisible ?? true)
    }

    func testMenuPageLaysOutReachableStatusLinksEditorWhenMenuDisplayIsEnabled() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }

        defaults.set(true, forKey: "showStatusMenu")
        defaults.removeObject(forKey: "statusLinks")
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26-layout.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let page = try XCTUnwrap(menuPage(in: window))
        layoutDescendants(of: window.contentView!)

        let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))
        let documentView = try XCTUnwrap(scrollView.documentView)
        let editor = try XCTUnwrap(findStatusLinksEditor(in: page))
        let card = try XCTUnwrap(
            ancestors(of: editor).first { $0.layer?.cornerRadius == 18 }
        )

        XCTAssertFalse(editor.isHidden)
        XCTAssertGreaterThan(editor.frame.width, 0)
        XCTAssertEqual(editor.frame.height, editor.layoutHeight, accuracy: 1)
        XCTAssertEqual(editor.subviews.count, 1, "Status Links host was torn down after page creation")
        let hostingView = try XCTUnwrap(editor.subviews.first)
        XCTAssertGreaterThan(hostingView.frame.width, 0)
        XCTAssertGreaterThan(hostingView.frame.height, 0)

        let editorRectInCard = editor.convert(editor.bounds, to: card)
        XCTAssertTrue(
            card.bounds.insetBy(dx: -1, dy: -1).contains(editorRectInCard),
            "Status Links editor is clipped by its card: editor=\(editorRectInCard), card=\(card.bounds)"
        )

        let editorRectInDocument = editor.convert(editor.bounds, to: documentView)
        XCTAssertTrue(
            documentView.bounds.insetBy(dx: -1, dy: -1).contains(editorRectInDocument),
            "Status Links editor is outside the scroll document: editor=\(editorRectInDocument), document=\(documentView.bounds)"
        )
        XCTAssertGreaterThan(
            documentView.bounds.height,
            scrollView.contentView.bounds.height,
            "Status Links editor must be reachable by scrolling"
        )

        XCTAssertTrue(
            editor.hostedContentIsWithinRevealBounds,
            "Hosted Status Links content must stay inside its clipped editor bounds"
        )
    }

    func testProductionMenuAddKeepsVisibleStatusLinksAnchorsFixedAtDocumentBottom() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }

        defaults.set(true, forKey: "showStatusMenu")
        defaults.set([
            ["title": "One", "url": "https://one.example"],
            ["title": "Two", "url": "https://two.example"]
        ], forKey: "statusLinks")
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26-add-anchor.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menu))
        window.setContentSize(NSSize(width: 800, height: 540))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let page = try XCTUnwrap(menuPage(in: window))
        layoutDescendants(of: page)
        let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))
        let documentView = try XCTUnwrap(scrollView.documentView)
        let editor = try XCTUnwrap(findStatusLinksEditor(in: page))
        let card = try XCTUnwrap(ancestors(of: editor).first { $0.layer?.cornerRadius == 18 })

        let geometry = DashboardScrollGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: scrollView.contentView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        XCTAssertGreaterThan(geometry.maximumOffset, 0)
        let bottomRect = geometry.visibleDocumentRect(
            forVisualOffset: max(0, geometry.maximumOffset - 1)
        )
        let documentY = geometry.contentOriginDocumentY(
            for: bottomRect,
            contentViewIsFlipped: scrollView.contentView.isFlipped
        )
        let contentOriginY = documentView.convert(
            NSPoint(x: documentView.bounds.minX, y: documentY),
            to: scrollView.contentView
        ).y
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: contentOriginY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        func visibleOffset() -> CGFloat {
            let current = DashboardScrollGeometry(
                documentBounds: documentView.bounds,
                viewportHeight: scrollView.contentView.bounds.height,
                isDocumentFlipped: documentView.isFlipped
            )
            return current.clampedVisualOffset(for: scrollView.contentView.convert(
                scrollView.contentView.bounds,
                to: documentView
            ))
        }
        func cardTop() -> CGFloat {
            let y = card.isFlipped ? card.bounds.minY : card.bounds.maxY
            return card.convert(NSPoint(x: card.bounds.minX, y: y), to: scrollView.contentView).y
        }

        let initialOffset = visibleOffset()
        let initialTitleY = try XCTUnwrap(editor.viewportAnchorY(
            identifier: NSUserInterfaceItemIdentifier("statusLinks.title.anchor"),
            in: scrollView.contentView
        ))
        let initialHeaderY = try XCTUnwrap(editor.viewportAnchorY(
            identifier: NSUserInterfaceItemIdentifier("statusLinks.header.anchor"),
            in: scrollView.contentView
        ))
        let initialCardTop = cardTop()
        let initialEditorTop = editor.convert(
            NSPoint(x: editor.bounds.minX, y: editor.isFlipped ? editor.bounds.minY : editor.bounds.maxY),
            to: scrollView.contentView
        ).y
        let initialDocumentHeight = documentView.bounds.height

        appDelegate.dashboardCompositionForTesting.addStatusLinkForTesting()

        let deadline = Date().addingTimeInterval(0.34)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            XCTAssertEqual(visibleOffset(), initialOffset, accuracy: 0.5)
            XCTAssertEqual(cardTop(), initialCardTop, accuracy: 0.5)
            XCTAssertEqual(
                editor.convert(
                    NSPoint(x: editor.bounds.minX, y: editor.isFlipped ? editor.bounds.minY : editor.bounds.maxY),
                    to: scrollView.contentView
                ).y,
                initialEditorTop,
                accuracy: 0.5
            )
            XCTAssertEqual(try XCTUnwrap(editor.viewportAnchorY(
                identifier: NSUserInterfaceItemIdentifier("statusLinks.title.anchor"),
                in: scrollView.contentView
            )), initialTitleY, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(editor.viewportAnchorY(
                identifier: NSUserInterfaceItemIdentifier("statusLinks.header.anchor"),
                in: scrollView.contentView
            )), initialHeaderY, accuracy: 0.5)
        }

        XCTAssertEqual(editor.rowCount, 3)
        XCTAssertEqual(editor.renderedRowCount, 3)
        XCTAssertGreaterThan(documentView.bounds.height, initialDocumentHeight)
        XCTAssertTrue(editor.hostedContentIsWithinRevealBounds)
    }

    func testStatusMenuToggleUpdatesDashboardImmediatelyAndPreservesConfiguredLinks() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }

        let customLinks = [
            StatusLink(title: "Status A", url: "https://status-a.example"),
            StatusLink(title: "Status B", url: "https://status-b.example")
        ]
        defaults.set(true, forKey: "showStatusMenu")
        defaults.set(try JSONEncoder().encode(customLinks), forKey: "statusLinks")

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26-toggle.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        layoutDescendants(of: window.contentView!)

        let visibleEditor = try XCTUnwrap(findStatusLinksEditor(in: try XCTUnwrap(menuPage(in: window))))
        XCTAssertEqual(visibleEditor.rowCount, customLinks.count)
        XCTAssertFalse(visibleEditor.isHidden)

        let toggleOff = try XCTUnwrap(
            firstControl(of: window.contentView!, as: NSSwitch.self) {
                $0.identifier?.rawValue == "showStatusMenu"
            }
        )
        toggleOff.state = .off
        _ = NSApp.sendAction(toggleOff.action!, to: toggleOff.target, from: toggleOff)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let hiddenPage = try XCTUnwrap(menuPage(in: window))
        layoutDescendants(of: window.contentView!)
        XCTAssertEqual(findStatusLinksEditors(in: hiddenPage).count, 1)
        let hiddenEditor = try XCTUnwrap(findStatusLinksEditor(in: hiddenPage))
        XCTAssertFalse(hiddenEditor.isVisible)
        XCTAssertTrue(hiddenEditor === visibleEditor, "Toggle must not recreate the hosting view")
        XCTAssertEqual(hiddenEditor.subviews.count, 1)
        XCTAssertFalse(defaults.bool(forKey: "showStatusMenu"))
        let persistedAfterHide = try JSONDecoder().decode(
            [StatusLink].self,
            from: try XCTUnwrap(defaults.data(forKey: "statusLinks"))
        )
        XCTAssertEqual(persistedAfterHide, customLinks)

        let toggleOn = try XCTUnwrap(
            firstControl(of: window.contentView!, as: NSSwitch.self) {
                $0.identifier?.rawValue == "showStatusMenu"
            }
        )
        toggleOn.state = .on
        _ = NSApp.sendAction(toggleOn.action!, to: toggleOn.target, from: toggleOn)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let restoredPage = try XCTUnwrap(menuPage(in: window))
        layoutDescendants(of: window.contentView!)
        XCTAssertEqual(findStatusLinksEditors(in: restoredPage).count, 1)
        let restoredEditor = try XCTUnwrap(findStatusLinksEditor(in: restoredPage))
        XCTAssertTrue(restoredEditor.isVisible)
        XCTAssertTrue(restoredEditor === visibleEditor, "Toggle must not recreate the hosting view")
        XCTAssertEqual(restoredEditor.subviews.count, 1)
        XCTAssertEqual(restoredEditor.rowCount, customLinks.count)
        XCTAssertEqual(restoredEditor.frame.height, restoredEditor.layoutHeight, accuracy: 1)
        let persistedAfterRestore = try JSONDecoder().decode(
            [StatusLink].self,
            from: try XCTUnwrap(defaults.data(forKey: "statusLinks"))
        )
        XCTAssertEqual(persistedAfterRestore, customLinks)
    }

    func testRapidStatusMenuTogglesKeepSingleHostingViewAndStableFinalFrames() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }

        let customLinks = [
            StatusLink(title: "Status A", url: "https://status-a.example"),
            StatusLink(title: "Status B", url: "https://status-b.example")
        ]
        defaults.set(true, forKey: "showStatusMenu")
        defaults.set(try JSONEncoder().encode(customLinks), forKey: "statusLinks")

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26-rapid.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        layoutDescendants(of: window.contentView!)

        let editor = try XCTUnwrap(findStatusLinksEditor(in: try XCTUnwrap(menuPage(in: window))))
        for index in 0..<6 {
            let shouldShow = index % 2 == 0
            let toggle = try XCTUnwrap(
                firstControl(of: window.contentView!, as: NSSwitch.self) {
                    $0.identifier?.rawValue == "showStatusMenu"
                }
            )
            toggle.state = shouldShow ? .on : .off
            _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))

            let page = try XCTUnwrap(menuPage(in: window))
            let editors = findStatusLinksEditors(in: page)
            XCTAssertEqual(editors.count, 1, "Rapid toggles must keep exactly one editor")
            XCTAssertTrue(editors.first === editor, "Rapid toggles must not recreate the hosting view")
            XCTAssertEqual(editors.first?.subviews.count, 1)
            XCTAssertEqual(editors.first?.isVisible, shouldShow)
            XCTAssertTrue(
                editors.first?.hostedContentIsWithinRevealBounds ?? false,
                "The hosted editor must stay inside its own reveal bounds during every toggle frame"
            )
        }

        let finalToggle = try XCTUnwrap(
            firstControl(of: window.contentView!, as: NSSwitch.self) {
                $0.identifier?.rawValue == "showStatusMenu"
            }
        )
        finalToggle.state = .on
        _ = NSApp.sendAction(finalToggle.action!, to: finalToggle.target, from: finalToggle)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        layoutDescendants(of: window.contentView!)
        let visibleEditor = try XCTUnwrap(findStatusLinksEditor(in: try XCTUnwrap(menuPage(in: window))))
        XCTAssertTrue(visibleEditor.isVisible)
        XCTAssertEqual(visibleEditor.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(visibleEditor.frame.height, visibleEditor.layoutHeight, accuracy: 1)
        XCTAssertEqual(visibleEditor.rowCount, customLinks.count)
        XCTAssertTrue(visibleEditor.hostedContentIsWithinRevealBounds)

        finalToggle.state = .off
        _ = NSApp.sendAction(finalToggle.action!, to: finalToggle.target, from: finalToggle)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        layoutDescendants(of: window.contentView!)
        let hiddenEditor = try XCTUnwrap(findStatusLinksEditor(in: try XCTUnwrap(menuPage(in: window))))
        XCTAssertFalse(hiddenEditor.isVisible)
        XCTAssertEqual(hiddenEditor.frame.height, 0, accuracy: 1)
        XCTAssertEqual(hiddenEditor.alphaValue, 0, accuracy: 0.01)
        XCTAssertEqual(hiddenEditor.rowCount, customLinks.count)

        finalToggle.state = .on
        let statusRow = try XCTUnwrap(finalToggle.superview)
        let editorCard = try XCTUnwrap(
            ancestors(of: hiddenEditor).first { $0.layer?.cornerRadius == 18 }
        )
        _ = NSApp.sendAction(finalToggle.action!, to: finalToggle.target, from: finalToggle)
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            layoutDescendants(of: window.contentView!)
            let editorRect = hiddenEditor.convert(hiddenEditor.bounds, to: editorCard)
            let statusRowRect = statusRow.convert(statusRow.bounds, to: editorCard)
            XCTAssertFalse(
                editorRect.intersects(statusRowRect),
                "The editor must never animate through the View Status sibling row"
            )
            XCTAssertTrue(
                hiddenEditor.hostedContentIsWithinRevealBounds,
                "The SwiftUI content must remain within the editor reveal boundary"
            )
        }
    }

    func testMenuPageHasOnePersistentOpenCodexSwitchIndependentFromCCSwitch() throws {
        let defaults = UserDefaults.standard
        let previousOpenCodexValue = defaults.object(forKey: AppPreferences.showOpenCodexMenuKey)
        let previousCCSwitchValue = defaults.object(forKey: "showOpenCCSwitchMenu")
        defer {
            if let previousOpenCodexValue {
                defaults.set(previousOpenCodexValue, forKey: AppPreferences.showOpenCodexMenuKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.showOpenCodexMenuKey)
            }
            if let previousCCSwitchValue {
                defaults.set(previousCCSwitchValue, forKey: "showOpenCCSwitchMenu")
            } else {
                defaults.removeObject(forKey: "showOpenCCSwitchMenu")
            }
        }

        defaults.set(true, forKey: AppPreferences.showOpenCodexMenuKey)
        defaults.set(true, forKey: "showOpenCCSwitchMenu")
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-109-menu.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }

        let page = appDelegate.dashboardCompositionForTesting.makePageForTesting(.menu)
        layoutDescendants(of: page)
        let openCodexSwitches = allControls(of: page, as: NSSwitch.self).filter {
            $0.identifier?.rawValue == AppPreferences.showOpenCodexMenuKey
        }
        XCTAssertEqual(openCodexSwitches.count, 1)
        let openCodexSwitch = try XCTUnwrap(openCodexSwitches.first)
        XCTAssertEqual(openCodexSwitch.state, .on)

        openCodexSwitch.state = .off
        let target = try XCTUnwrap(openCodexSwitch.target as? NSObject)
        _ = target.perform(openCodexSwitch.action, with: openCodexSwitch)
        XCTAssertFalse(AppPreferences(defaults: defaults).showOpenCodexMenu)
        XCTAssertTrue(AppPreferences(defaults: defaults).showOpenCCSwitchMenu)

        let reopenedPage = appDelegate.dashboardCompositionForTesting.makePageForTesting(.menu)
        layoutDescendants(of: reopenedPage)
        let reloadedOpenCodexSwitches = allControls(of: reopenedPage, as: NSSwitch.self).filter {
            $0.identifier?.rawValue == AppPreferences.showOpenCodexMenuKey
        }
        XCTAssertEqual(reloadedOpenCodexSwitches.count, 1)
        XCTAssertEqual(reloadedOpenCodexSwitches.first?.state, .off)
    }

    func testProductionSettingsPagesPreserveSectionRowGeometryAndNativeActions() throws {
        let defaults = UserDefaults.standard
        let previousStatusMenu = defaults.object(forKey: "showStatusMenu")
        defaults.set(true, forKey: "showStatusMenu")
        defer {
            if let previousStatusMenu {
                defaults.set(previousStatusMenu, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
        }
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-27-pages.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }

        for section in [DashboardSection.general, .menuBar, .menu, .advanced] {
            let page = appDelegate.dashboardCompositionForTesting.makePageForTesting(section)
            layoutDescendants(of: page)

            let scrollView = try XCTUnwrap(
                firstDescendant(of: page, as: NSScrollView.self),
                "Missing production settings scroll view for \(section)"
            )
            XCTAssertTrue(scrollView.hasVerticalScroller)
            XCTAssertFalse(scrollView.hasHorizontalScroller)
            let documentView = try XCTUnwrap(scrollView.documentView)
            let pageStack = try XCTUnwrap(
                firstDescendant(of: documentView, as: NSStackView.self),
                "Missing settings page stack for \(section)"
            )
            XCTAssertFalse(pageStack.arrangedSubviews.isEmpty)

            for sectionView in pageStack.arrangedSubviews {
                let sectionStack = try XCTUnwrap(sectionView as? NSStackView)
                XCTAssertEqual(sectionStack.arrangedSubviews.count, 2)
                let heading = try XCTUnwrap(sectionStack.arrangedSubviews.first as? NSTextField)
                XCTAssertEqual(heading.font?.pointSize ?? -1, 17, accuracy: 0.01)
                let card = sectionStack.arrangedSubviews[1]
                XCTAssertEqual(card.layer?.cornerRadius ?? -1, 18, accuracy: 0.01)
                let rowsStack = try XCTUnwrap(
                    firstDescendant(of: card, as: NSStackView.self)
                )
                XCTAssertFalse(rowsStack.arrangedSubviews.isEmpty)
                for row in rowsStack.arrangedSubviews where !(row is NSBox) && !row.isHidden {
                    XCTAssertGreaterThanOrEqual(row.frame.height, 62)
                }
            }

            for control in allControls(of: page, as: NSSwitch.self) {
                XCTAssertNotNil(control.target, "Switch lost its target on \(section)")
                XCTAssertNotNil(control.action, "Switch lost its action on \(section)")
            }
            for control in allControls(of: page, as: NSPopUpButton.self) {
                XCTAssertNotNil(control.target, "Popup lost its target on \(section)")
                XCTAssertNotNil(control.action, "Popup lost its action on \(section)")
            }
        }
    }

    func testMenuBarAndAdvancedFirstMountStartAtNativeTopWithoutBlankRegion() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-30-top-blank.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }

        for section in [DashboardSection.general, .menuBar, .advanced] {
            let page = appDelegate.dashboardCompositionForTesting.makePageForTesting(section)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = page
            window.layoutIfNeeded()
            layoutDescendants(of: page)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            defer { window.orderOut(nil) }

            let scrollView = try XCTUnwrap(
                firstDescendant(of: page, as: NSScrollView.self),
                "Missing settings scroll view for \(section)"
            )
            let documentView = try XCTUnwrap(scrollView.documentView)
            let pageStack = try XCTUnwrap(
                firstDescendant(of: documentView, as: NSStackView.self)
            )
            let firstSection = try XCTUnwrap(pageStack.arrangedSubviews.first)
            let firstHeading = try XCTUnwrap(
                firstDescendant(of: firstSection, as: NSTextField.self)
            )
            let visibleRect = scrollView.contentView.convert(
                scrollView.contentView.bounds,
                to: documentView
            )
            let firstHeadingRect = firstHeading.convert(
                firstHeading.bounds,
                to: documentView
            )
            let viewportFrameInPage = scrollView.convert(scrollView.bounds, to: page)

            XCTAssertTrue(documentView.isFlipped)
            XCTAssertEqual(viewportFrameInPage.minY - page.bounds.minY, 52, accuracy: 1)
            XCTAssertEqual(visibleRect.minY, documentView.bounds.minY, accuracy: 1)
            XCTAssertEqual(
                pageStack.frame.minY,
                documentView.bounds.minY,
                accuracy: 1
            )
            XCTAssertLessThanOrEqual(
                visibleRect.maxY,
                documentView.bounds.maxY + 1
            )
            XCTAssertTrue(
                visibleRect.intersects(firstHeadingRect),
                "First heading is not visible on initial mount for \(section): visible=\(visibleRect), heading=\(firstHeadingRect)"
            )
            let headingInPage = firstHeading.convert(firstHeading.bounds, to: page)
            XCTAssertGreaterThanOrEqual(headingInPage.minY, viewportFrameInPage.minY - 1)
            XCTAssertLessThanOrEqual(headingInPage.maxY, viewportFrameInPage.maxY + 1)
        }
    }

    func testGeneralMenuBarAndAdvancedPageReplacementResetsNativeTop() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-30-page-replacement.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(
            appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general)
        )

        for section in [DashboardSection.general, .menuBar, .advanced] {
            appDelegate.dashboardCompositionForTesting.showSection(section)
            window.displayIfNeeded()
            layoutDescendants(of: window.contentView!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))

            let scrollView = try XCTUnwrap(
                firstDescendant(of: window.contentView!, as: NSScrollView.self),
                "Missing replaced settings scroll view for \(section)"
            )
            let document = try XCTUnwrap(scrollView.documentView)
            let visible = scrollView.contentView.convert(
                scrollView.contentView.bounds,
                to: document
            )
            let stack = try XCTUnwrap(firstDescendant(of: document, as: NSStackView.self))
            let firstSection = try XCTUnwrap(stack.arrangedSubviews.first)
            let firstHeading = try XCTUnwrap(
                firstDescendant(of: firstSection, as: NSTextField.self)
            )
            let firstHeadingRect = firstHeading.convert(firstHeading.bounds, to: document)
            let page = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.contentHost.subviews.first)
            let viewportFrameInPage = scrollView.convert(scrollView.bounds, to: page)
            XCTAssertTrue(document.isFlipped)
            XCTAssertEqual(
                viewportFrameInPage.minY - page.bounds.minY,
                52,
                accuracy: 1,
                "Settings scroll viewport lost its measured non-document top inset for \(section)"
            )
            XCTAssertEqual(
                visible.minY,
                document.bounds.minY,
                accuracy: 1,
                "Initial visible origin mismatch for \(section): visible=\(visible), document=\(document.bounds), clipBounds=\(scrollView.contentView.bounds), contentInsets=\(scrollView.contentInsets)"
            )
            XCTAssertEqual(stack.frame.minY, document.bounds.minY, accuracy: 1)
            XCTAssertTrue(
                visible.intersects(firstHeadingRect),
                "Replaced \(section) first heading is not visible: visible=\(visible), heading=\(firstHeadingRect)"
            )
            let headingInPage = firstHeading.convert(firstHeading.bounds, to: page)
            XCTAssertGreaterThanOrEqual(headingInPage.minY, viewportFrameInPage.minY - 1)
            XCTAssertLessThanOrEqual(headingInPage.maxY, viewportFrameInPage.maxY + 1)
        }
    }

    func testProductionSettingsScrollHostsKeepNativeElasticityAndLegalEndpointFrames() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-30-endpoint.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(
            appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general)
        )

        for section in [DashboardSection.general, .menuBar, .advanced] {
            appDelegate.dashboardCompositionForTesting.showSection(section)
            window.displayIfNeeded()
            layoutDescendants(of: window.contentView!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))

            let scrollView = try XCTUnwrap(
                firstDescendant(of: window.contentView!, as: NSScrollView.self),
                "Missing settings scroll view for \(section)"
            )
            let contentView = scrollView.contentView
            let document = try XCTUnwrap(scrollView.documentView)
            let page = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.contentHost.subviews.first)
            let viewportFrameInPage = scrollView.convert(scrollView.bounds, to: page)
            let stack = try XCTUnwrap(firstDescendant(of: document, as: NSStackView.self))
            let firstHeading = try XCTUnwrap(
                firstDescendant(of: stack.arrangedSubviews.first!, as: NSTextField.self)
            )
            let geometry = DashboardScrollGeometry(
                documentBounds: document.bounds,
                viewportHeight: contentView.bounds.height,
                isDocumentFlipped: document.isFlipped
            )

            XCTAssertFalse(scrollView.automaticallyAdjustsContentInsets)
            XCTAssertEqual(scrollView.contentInsets.top, 0, accuracy: 0.001)
            XCTAssertEqual(scrollView.contentInsets.bottom, 0, accuracy: 0.001)
            XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
            XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
            XCTAssertTrue(document.isFlipped)
            XCTAssertEqual(viewportFrameInPage.minY - page.bounds.minY, 52, accuracy: 1)
            XCTAssertEqual(viewportFrameInPage.maxY, page.bounds.maxY, accuracy: 1)

            let proposals = geometry.maximumOffset > 1
                ? [CGFloat(0), geometry.maximumOffset, geometry.maximumOffset * 0.72, geometry.maximumOffset, CGFloat(0)]
                : [CGFloat(0)]
            var bottomVisible: NSRect?
            for proposal in proposals {
                let targetRect = geometry.visibleDocumentRect(forVisualOffset: proposal)
                let targetDocumentY = geometry.contentOriginDocumentY(
                    for: targetRect,
                    contentViewIsFlipped: contentView.isFlipped
                )
                let targetContentY = document.convert(
                    NSPoint(x: document.bounds.minX, y: targetDocumentY),
                    to: contentView
                ).y
                contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: targetContentY))
                scrollView.reflectScrolledClipView(contentView)

                let visible = contentView.convert(contentView.bounds, to: document)
                let actual = geometry.visualOffset(for: visible)
                XCTAssertEqual(actual, proposal, accuracy: 1, "Native endpoint replay moved \(section) unexpectedly")
                XCTAssertGreaterThanOrEqual(visible.minY, document.bounds.minY - 1)
                XCTAssertLessThanOrEqual(visible.maxY, document.bounds.maxY + 1)
                if abs(proposal - geometry.maximumOffset) < 0.001 {
                    bottomVisible = visible
                }
            }

            let visibleAtTop = contentView.convert(contentView.bounds, to: document)
            let firstHeadingRect = firstHeading.convert(firstHeading.bounds, to: document)
            let visibleAtBottom = try XCTUnwrap(bottomVisible)
            XCTAssertEqual(visibleAtBottom.maxY, document.bounds.maxY, accuracy: 1)
            XCTAssertEqual(geometry.clampedVisualOffset(for: visibleAtTop), 0, accuracy: 1)
            XCTAssertTrue(visibleAtTop.intersects(firstHeadingRect))
            XCTAssertEqual(stack.frame.minY, document.bounds.minY, accuracy: 1)
        }
    }

    func testDashboardSettingsFactoryPreservesNativeControlValuesAndActions() throws {
        final class ActionTarget: NSObject {
            var switchActionCount = 0
            var popupActionCount = 0

            @objc func switchChanged(_ sender: NSSwitch) {
                switchActionCount += 1
            }

            @objc func popupChanged(_ sender: NSPopUpButton) {
                popupActionCount += 1
            }
        }

        let target = ActionTarget()
        let control = DashboardSettingsComponents.makeSwitch(
            identifier: "factory.switch",
            isOn: true,
            target: target,
            action: #selector(ActionTarget.switchChanged(_:))
        )
        XCTAssertEqual(control.identifier?.rawValue, "factory.switch")
        XCTAssertEqual(control.state, .on)
        _ = target.perform(control.action, with: control)
        XCTAssertEqual(target.switchActionCount, 1)

        let popup = DashboardSettingsComponents.makePopUpButton(
            identifier: "factory.popup",
            items: [
                .init(title: "First", representedObject: "first"),
                .init(title: "Second", representedObject: "second")
            ],
            selectedIndex: 1,
            target: target,
            action: #selector(ActionTarget.popupChanged(_:))
        )
        XCTAssertEqual(popup.identifier?.rawValue, "factory.popup")
        XCTAssertEqual(popup.indexOfSelectedItem, 1)
        XCTAssertEqual(popup.item(at: 1)?.representedObject as? String, "second")
        _ = target.perform(popup.action, with: popup)
        XCTAssertEqual(target.popupActionCount, 1)
    }

    func testStatusMenuEntryFollowsShowStatusMenuPreferenceInMainMenu() {
        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                openOpenCodex: {},
                quit: {},
                switchProvider: { _ in },
                switchOpenCodexPreference: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let baseInput = StatusItemController.MenuInput(
            openCodexCards: [],
            openCodexState: nil,
            openCodexSwitchInFlight: false,
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: nil,
            statusLinks: [
                StatusLink(title: "Status", url: "https://status.example")
            ],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showOpenCodexMenu: true,
            showStatusMenu: false
        )
        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: baseInput,
            settings: settings
        )
        XCTAssertNil(
            controller.menuItemsForTesting.first {
                $0.title == "查看状态" || $0.title == "View Status"
            }
        )

        let visibleInput = StatusItemController.MenuInput(
            openCodexCards: [],
            openCodexState: nil,
            openCodexSwitchInFlight: false,
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: nil,
            statusLinks: [
                StatusLink(title: "Status", url: "https://status.example")
            ],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showOpenCodexMenu: true,
            showStatusMenu: true
        )
        controller.updateMenu(input: visibleInput)
        let statusItem = try? XCTUnwrap(
            controller.menuItemsForTesting.first {
                $0.title == "查看状态" || $0.title == "View Status"
            }
        )
        XCTAssertEqual(statusItem?.submenu?.items.map(\.title), ["Status"])

        controller.updateMenu(input: baseInput)
        XCTAssertNil(
            controller.menuItemsForTesting.first {
                $0.title == "查看状态" || $0.title == "View Status"
            }
        )
    }

    func testOpenAIAccountSubtitleUsesStaticMiddleTruncationAndHidesOutsideOfficialCodex() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                openOpenCodex: {},
                quit: {},
                switchProvider: { _ in },
                switchOpenCodexPreference: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        func input(account: OpenAIAccountPresentation?) -> StatusItemController.MenuInput {
            StatusItemController.MenuInput(
                openCodexCards: [],
                openCodexState: nil,
                openCodexSwitchInFlight: false,
                choices: [],
                quickSwitchSummaries: [:],
                activeClient: .codex,
                openAIAccount: account,
                statusLinks: [],
                showQuickSwitchMenu: false,
                showOpenChatGPTMenu: false,
                showOpenCCSwitchMenu: false,
                showOpenCodexMenu: false,
                showStatusMenu: false
            )
        }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let longEmail = "account-alpha-20260827-singapore-long-identifier-beta-usage-quota-gamma-openai-official-delta-window-resize-epsilon-manual-check@gmail.com"
        controller.start(
            snapshot: .official("OpenAI Official", 83, "7-Day Quota", "2 hours", date),
            refreshDate: date,
            menuInput: input(account: OpenAIAccountPresentation(email: longEmail, subscription: .proFiveX)),
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let accountView = try XCTUnwrap(
            overview.subviews.compactMap { $0 as? AccountEmailView }.first
        )
        let accountLabel = accountView.emailLabel
        XCTAssertEqual(accountLabel.font?.pointSize, 13)
        XCTAssertEqual(accountLabel.textColor, .secondaryLabelColor)
        XCTAssertEqual(accountLabel.lineBreakMode, .byClipping)
        XCTAssertEqual(AccountEmailTextField.tooltipDelay, 0.15, accuracy: 0.001)
        XCTAssertFalse(accountLabel.isTooltipScheduled)
        XCTAssertFalse(accountLabel.isTooltipVisible)
        let tooltipEmail = "huanmeng2048609305@163.com"
        let tooltipFont = NSFont.toolTipsFont(ofSize: NSFont.smallSystemFontSize)
        let tooltipLayout = AccountEmailTooltipLayout.make(
            for: tooltipEmail,
            font: tooltipFont
        )
        XCTAssertGreaterThanOrEqual(
            tooltipLayout.textWidth,
            AccountMarqueeView.textWidth(of: tooltipEmail, font: tooltipFont)
                + AccountEmailTooltipLayout.textMeasurementSlack
        )
        let wrappedTooltipEmail = "huanmeng2048609305137151358071145141919810@gmail.com"
        let wrappedTooltipLayout = AccountEmailTooltipLayout.make(
            for: wrappedTooltipEmail,
            font: tooltipFont
        )
        let minimumSingleLineHeight = ceil(tooltipFont.ascender - tooltipFont.descender + 2)
        XCTAssertGreaterThan(wrappedTooltipLayout.textHeight, minimumSingleLineHeight)
        XCTAssertLessThanOrEqual(
            wrappedTooltipLayout.textWidth,
            AccountEmailTooltipLayout.maximumTextWidth
        )
        XCTAssertEqual(
            wrappedTooltipLayout.contentSize.height,
            wrappedTooltipLayout.textHeight + AccountEmailTooltipLayout.verticalInset * 2
        )
        let threeLineTooltipEmail = String(repeating: "x", count: 110) + "@gmail.com"
        let threeLineTooltipLayout = AccountEmailTooltipLayout.make(
            for: threeLineTooltipEmail,
            font: tooltipFont
        )
        XCTAssertGreaterThan(threeLineTooltipLayout.textHeight, wrappedTooltipLayout.textHeight)
        XCTAssertGreaterThan(
            threeLineTooltipLayout.textHeight,
            minimumSingleLineHeight * 2
        )
        XCTAssertGreaterThan(tooltipLayout.textHeight, 0)
        XCTAssertFalse(accountView.isMarqueeEnabled)
        XCTAssertEqual(accountView.fullEmail, longEmail)
        XCTAssertTrue(accountView.textLayout.isTruncated)
        XCTAssertTrue(accountView.displayedEmail.contains(AccountEmailTextLayout.ellipsis))
        XCTAssertTrue(accountView.displayedEmail.hasPrefix(accountView.textLayout.prefix))
        XCTAssertTrue(accountView.displayedEmail.hasSuffix("@gmail.com"))
        XCTAssertGreaterThan(accountView.textLayout.prefix.count, 0)
        XCTAssertLessThanOrEqual(
            accountView.textLayout.measuredTextWidth,
            accountView.bounds.width + 0.001
        )
        XCTAssertEqual(accountView.emailLabel.frame, accountView.bounds)
        XCTAssertEqual(accountView.emailLabel.toolTip, longEmail)
        XCTAssertEqual(accountView.emailLabel.accessibilityLabel(), longEmail)
        XCTAssertEqual(accountView.emailLabel.accessibilityValue() as? String, longEmail)
        XCTAssertFalse(accountLabel.isEmailHovered)
        XCTAssertFalse(accountLabel.isUnderlined)
        accountLabel.setHoveringForTesting(true)
        XCTAssertTrue(accountLabel.isEmailHovered)
        XCTAssertTrue(accountLabel.isUnderlined)
        XCTAssertEqual(accountLabel.toolTip, longEmail)
        accountLabel.setHoveringForTesting(false)
        XCTAssertFalse(accountLabel.isEmailHovered)
        XCTAssertFalse(accountLabel.isUnderlined)
        XCTAssertEqual(
            accountView.tooltipText(at: NSPoint(x: 1, y: accountView.bounds.midY)),
            longEmail
        )
        XCTAssertNil(accountView.tooltipText(at: NSPoint(x: -1, y: accountView.bounds.midY)))
        XCTAssertNil(accountView.emailLabel.target)
        XCTAssertNil(accountView.emailLabel.action)
        XCTAssertNil(accountView.layer?.animation(forKey: AccountMarqueeView.animationKey))
        XCTAssertNil(accountView.emailLabel.layer?.animation(forKey: AccountMarqueeView.animationKey))
        XCTAssertLessThanOrEqual(accountView.frame.maxX, overview.bounds.maxX)
        let subscriptionLabel = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.stringValue == "Pro · 5x"
            }
        )
        XCTAssertEqual(subscriptionLabel.font?.pointSize, 13)
        XCTAssertEqual(subscriptionLabel.textColor, .secondaryLabelColor)
        XCTAssertEqual(subscriptionLabel.alignment, .right)
        XCTAssertEqual(subscriptionLabel.lineBreakMode, .byTruncatingTail)
        let subscriptionTextWidth = AccountMarqueeView.textWidth(
            of: subscriptionLabel.stringValue,
            font: try XCTUnwrap(subscriptionLabel.font)
        )
        let expectedAccountFrame = try XCTUnwrap(
            OpenCodexCardLayout.frames(
                for: .quota,
                includesAccount: true,
                includesSubscription: true,
                subscriptionTextWidth: subscriptionTextWidth
            ).account
        )
        XCTAssertEqual(accountView.frame, expectedAccountFrame)
        let subscriptionFrame = try XCTUnwrap(
            OpenCodexCardLayout.frames(
                for: .quota,
                includesAccount: true,
                includesSubscription: true
            ).subscription
        )
        XCTAssertEqual(subscriptionLabel.frame, subscriptionFrame)
        XCTAssertTrue(subscriptionLabel.superview === overview)
        XCTAssertEqual(accountView.frame.minY, subscriptionLabel.frame.minY)
        XCTAssertEqual(accountView.frame.height, subscriptionLabel.frame.height)
        XCTAssertEqual(
            accountView.frame.maxX,
            subscriptionLabel.frame.maxX
                - subscriptionTextWidth
                - OpenCodexCardLayout.subscriptionTextSafetyGap,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            subscriptionLabel.frame.maxX - subscriptionTextWidth - accountView.frame.maxX,
            OpenCodexCardLayout.subscriptionTextSafetyGap - 0.001
        )
        XCTAssertGreaterThanOrEqual(
            OpenCodexCardLayout.subscriptionTextSafetyGap,
            8
        )
        XCTAssertGreaterThan(accountView.frame.maxX, subscriptionLabel.frame.minX)
        XCTAssertEqual(subscriptionLabel.frame.maxX, overview.bounds.width - 14)
        XCTAssertNotNil(
            allControls(of: overview, as: NSTextField.self).first {
                $0.stringValue == "83%"
            }
        )

        controller.updateMenu(
            input: input(account: OpenAIAccountPresentation(email: "person@example.com", subscription: .proTwentyX))
        )
        let switchedOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let switchedAccountView = try XCTUnwrap(
            switchedOverview.subviews.compactMap { $0 as? AccountEmailView }.first
        )
        let switchedSubscriptionLabel = try XCTUnwrap(
            allControls(of: switchedOverview, as: NSTextField.self).first {
                $0.stringValue == "Pro · 20x"
            }
        )
        let switchedSubscriptionTextWidth = AccountMarqueeView.textWidth(
            of: switchedSubscriptionLabel.stringValue,
            font: try XCTUnwrap(switchedSubscriptionLabel.font)
        )
        XCTAssertFalse(switchedAccountView.textLayout.isTruncated)
        XCTAssertFalse(switchedAccountView.isMarqueeEnabled)
        XCTAssertEqual(switchedAccountView.emailLabel.frame.width, switchedAccountView.bounds.width)
        XCTAssertEqual(switchedAccountView.displayedEmail, "person@example.com")
        XCTAssertEqual(switchedAccountView.emailLabel.toolTip, "person@example.com")
        XCTAssertEqual(
            switchedAccountView.emailLabel.accessibilityValue() as? String,
            "person@example.com"
        )
        XCTAssertEqual(
            switchedAccountView.frame.maxX,
            switchedSubscriptionLabel.frame.maxX
                - switchedSubscriptionTextWidth
                - OpenCodexCardLayout.subscriptionTextSafetyGap,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(switchedAccountView.frame.maxX, switchedSubscriptionLabel.frame.minX)
        XCTAssertNil(
            allControls(of: switchedOverview, as: NSTextField.self).first {
                $0.stringValue.contains(longEmail)
            }
        )
        XCTAssertNil(
            allControls(of: switchedOverview, as: NSTextField.self).first {
                $0.stringValue == "Pro · 5x"
            }
        )

        controller.updateMenu(
            input: input(account: OpenAIAccountPresentation(email: nil))
        )
        let unavailableOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertNotNil(
            allControls(of: unavailableOverview, as: NSTextField.self).first {
                $0.stringValue == "Account unavailable"
            }
        )

        controller.update(
            snapshot: .balance(
                "Relay",
                12.34,
                "USD",
                URL(string: "https://relay.example"),
                date
            ),
            refreshDate: date,
            menuInput: input(account: nil),
            settings: settings
        )
        let nonOfficialOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertFalse(
            allControls(of: nonOfficialOverview, as: NSTextField.self).contains {
                $0.stringValue.contains("Account") || $0.stringValue.contains("account-")
            }
        )
        XCTAssertTrue(
            allControls(of: nonOfficialOverview, as: AccountEmailView.self).isEmpty
        )
    }

    func testAccountEmailTextLayoutPreservesDomainsAndUnicodeWithoutOverflow() {
        let font = NSFont.systemFont(ofSize: 13)
        let short = "person@example.com"
        let shortLayout = AccountEmailTextLayout.make(
            for: short,
            font: font,
            availableWidth: AccountMarqueeView.textWidth(of: short, font: font) + 1
        )
        XCTAssertFalse(shortLayout.isTruncated)
        XCTAssertEqual(shortLayout.displayText, short)

        let long = "前缀用户-非常长的标识-東京と한글@gmail.com"
        let longLayout = AccountEmailTextLayout.make(
            for: long,
            font: font,
            availableWidth: 150
        )
        XCTAssertTrue(longLayout.isTruncated)
        XCTAssertTrue(longLayout.displayText.contains(AccountEmailTextLayout.ellipsis))
        XCTAssertTrue(longLayout.displayText.hasSuffix("@gmail.com"))
        XCTAssertTrue(longLayout.prefix.hasPrefix("前"))
        XCTAssertLessThanOrEqual(longLayout.measuredTextWidth, 150.001)

        let longDomain = "local-part-with-unicode-👩‍💻-and-graphemes@subdomain-with-a-very-long-name.example"
        let longDomainLayout = AccountEmailTextLayout.make(
            for: longDomain,
            font: font,
            availableWidth: 118
        )
        XCTAssertTrue(longDomainLayout.isTruncated)
        XCTAssertTrue(longDomainLayout.displayText.contains(AccountEmailTextLayout.ellipsis))
        XCTAssertTrue(longDomainLayout.displayText.hasSuffix("example"))
        if longDomainLayout.displayText.contains("👩") {
            XCTAssertTrue(longDomainLayout.displayText.contains("👩‍💻"))
        }
        XCTAssertLessThanOrEqual(longDomainLayout.measuredTextWidth, 118.001)

        let languages = [
            "account-with-a-long-name@example.com",
            "账号-非常长@example.cn",
            "帳號-非常長@example.tw",
            "帳號-非常長@example.hk",
            "アカウント-とても長い@example.jp",
            "계정-매우긴이름@example.kr",
            "cuenta-muy-larga@example.es",
            "konto-sehr-lang@example.de",
            "compte-très-long@example.fr"
        ]
        for email in languages {
            let layout = AccountEmailTextLayout.make(
                for: email,
                font: font,
                availableWidth: 100
            )
            XCTAssertLessThanOrEqual(
                layout.measuredTextWidth,
                100.001,
                "display overflowed for \(email)"
            )
            XCTAssertTrue(layout.displayText.contains(AccountEmailTextLayout.ellipsis))
        }
    }

    func testAccountEmailViewRecomputesStaticDisplayForDynamicTextAndResize() throws {
        let email = "resize-sensitive-account@example.com"
        let view = AccountEmailView(
            email: email,
            font: .systemFont(ofSize: 13),
            textColor: .secondaryLabelColor,
            frame: NSRect(x: 14, y: 75, width: 110, height: 18)
        )
        let initialFrame = view.frame
        XCTAssertTrue(view.textLayout.isTruncated)
        XCTAssertEqual(view.emailLabel.toolTip, email)
        XCTAssertNil(view.emailLabel.layer?.animation(forKey: AccountMarqueeView.animationKey))

        view.setFrameSize(NSSize(width: 260, height: 18))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.textLayout.isTruncated)
        XCTAssertEqual(view.displayedEmail, email)
        XCTAssertEqual(view.emailLabel.frame, view.bounds)

        let updatedEmail = "动态更新-長い-アカウント@example.example"
        view.updateText(updatedEmail)
        XCTAssertEqual(view.fullEmail, updatedEmail)
        XCTAssertEqual(view.emailLabel.toolTip, updatedEmail)
        XCTAssertEqual(view.emailLabel.accessibilityValue() as? String, updatedEmail)
        XCTAssertEqual(
            view.tooltipText(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY)),
            updatedEmail
        )

        view.emailLabel.setHoveringForTesting(true)
        XCTAssertTrue(view.emailLabel.isUnderlined)

        view.setFrameSize(NSSize(width: 92, height: 18))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.textLayout.isTruncated)
        XCTAssertTrue(view.emailLabel.isUnderlined)
        XCTAssertLessThanOrEqual(
            view.textLayout.measuredTextWidth,
            view.bounds.width + 0.001
        )
        XCTAssertEqual(view.frame.minX, initialFrame.minX)
        XCTAssertEqual(view.frame.minY, initialFrame.minY)
        XCTAssertEqual(view.frame.height, initialFrame.height)
        view.emailLabel.setHoveringForTesting(false)
        XCTAssertFalse(view.emailLabel.isUnderlined)
        XCTAssertNil(view.emailLabel.layer?.animation(forKey: AccountMarqueeView.animationKey))
    }

    func testAccountMarqueeLayoutUsesViewportInsetAndActualOverflowAcrossLanguages() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let viewport = NSRect(x: 14, y: 75, width: 128, height: 18)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let short = AccountMarqueeLayout(
            measuredTextWidth: 32,
            clipBounds: viewport
        )

        XCTAssertFalse(short.isScrollable)
        XCTAssertEqual(short.edgeFadeWidth, 0, accuracy: 0.001)
        XCTAssertEqual(short.scrollDistance, 0, accuracy: 0.001)
        XCTAssertEqual(short.maskLocations, [])
        XCTAssertEqual(short.contentFrame, viewport)

        for language in [
            AppLanguage.english,
            .simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese,
            .korean,
            .spanish,
            .german,
            .french
        ] {
            AppLanguage.selected = language
            let localizedText = String(
                repeating: tr(.keyResponseParsers7DayQuota2) + " ",
                count: 6
            )
            let textWidth = AccountMarqueeView.textWidth(of: localizedText, font: font)
            let layout = AccountMarqueeLayout(
                measuredTextWidth: textWidth,
                clipBounds: viewport
            )

            XCTAssertTrue(layout.isScrollable, "expected overflow for \(language)")
            XCTAssertEqual(layout.contentFrame.minX, viewport.minX)
            XCTAssertEqual(layout.contentFrame.minY, viewport.minY)
            XCTAssertEqual(layout.contentFrame.width, textWidth, accuracy: 0.001)
            XCTAssertEqual(layout.textOverflow, textWidth - viewport.width, accuracy: 0.001)
            XCTAssertEqual(layout.trailingFadeBuffer, layout.edgeFadeWidth, accuracy: 0.001)
            XCTAssertEqual(
                layout.scrollDistance,
                layout.textOverflow + layout.trailingFadeBuffer,
                accuracy: 0.001
            )
            XCTAssertEqual(
                layout.endpointContentFrame.maxX,
                layout.trailingOpaqueMaxX,
                accuracy: 0.001
            )
            XCTAssertLessThanOrEqual(
                layout.endpointContentFrame.maxX,
                viewport.maxX - layout.edgeFadeWidth + 0.001
            )
            XCTAssertEqual(layout.clipBounds, viewport)
            XCTAssertEqual(layout.maskLocations.count, 4)
            XCTAssertEqual(layout.maskLocations.first ?? -1, 0, accuracy: 0.001)
            XCTAssertEqual(layout.maskLocations.last ?? -1, 1, accuracy: 0.001)
            XCTAssertGreaterThan(layout.maskLocations[1], 0)
            XCTAssertLessThan(layout.maskLocations[2], 1)
        }
    }

    func testAccountMarqueeRecomputesForDynamicTextAndNarrowWideNarrowResize() throws {
        let shortText = "Quota"
        let longText = String(repeating: "A very long localized quota title ", count: 8)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let view = AccountMarqueeView(
            text: shortText,
            font: font,
            textColor: .labelColor,
            frame: NSRect(x: 14, y: 75, width: 128, height: 18)
        )

        XCTAssertFalse(view.isScrollable)
        XCTAssertFalse(view.showsEdgeFade)

        view.updateText(longText)
        view.layout()
        XCTAssertTrue(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertEqual(view.frame.minX, 14, accuracy: 0.001)
        XCTAssertEqual(view.accountLabel.frame.minX, view.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(
            view.scrollOverflow,
            view.measuredTextWidth - view.bounds.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            view.scrollDistance,
            view.scrollOverflow + view.edgeFadeInset,
            accuracy: 0.001
        )
        XCTAssertNil(view.layer?.mask)
        view.applyScrollOffsetForTesting(-1)
        XCTAssertTrue(view.isScrolling)
        XCTAssertTrue(view.showsEdgeFade)
        let narrowMask = try XCTUnwrap(view.layer?.mask as? CAGradientLayer)
        XCTAssertEqual(narrowMask.frame, view.layer?.bounds ?? view.bounds)
        XCTAssertEqual(narrowMask.startPoint, CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(narrowMask.endPoint, CGPoint(x: 1, y: 0.5))

        let animation = AccountMarqueeView.scrollAnimation(
            forOverflow: view.scrollOverflow,
            trailingFadeBuffer: view.edgeFadeInset
        )
        let endpoint = try XCTUnwrap(animation.values?[2] as? NSNumber)
        XCTAssertEqual(endpoint.doubleValue, -Double(view.scrollDistance), accuracy: 0.001)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearanceName)
            view.layout()
            let mask = try XCTUnwrap(view.layer?.mask as? CAGradientLayer)
            XCTAssertEqual(mask.frame, view.layer?.bounds ?? view.bounds)
            XCTAssertEqual(mask.startPoint, CGPoint(x: 0, y: 0.5))
            XCTAssertEqual(mask.endPoint, CGPoint(x: 1, y: 0.5))
            XCTAssertEqual(mask.locations?.count, 4)
        }

        let wideWidth = view.measuredTextWidth + 32
        view.setFrameSize(NSSize(width: wideWidth, height: 18))
        view.layout()
        XCTAssertFalse(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertNil(view.layer?.mask)
        XCTAssertEqual(view.accountLabel.frame.minX, view.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(view.accountLabel.frame.width, view.bounds.width, accuracy: 0.001)

        view.setFrameSize(NSSize(width: 64, height: 18))
        view.layout()
        XCTAssertTrue(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertEqual(view.accountLabel.frame.minX, view.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(
            view.scrollOverflow,
            view.measuredTextWidth - view.bounds.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            view.scrollDistance,
            view.scrollOverflow + view.edgeFadeInset,
            accuracy: 0.001
        )
        XCTAssertNil(view.layer?.mask)
        view.applyScrollOffsetForTesting(-1)
        XCTAssertTrue(view.isScrolling)
        XCTAssertTrue(view.showsEdgeFade)
        let restoredMask = try XCTUnwrap(view.layer?.mask as? CAGradientLayer)
        XCTAssertEqual(restoredMask.frame, view.layer?.bounds ?? view.bounds)
        XCTAssertEqual(restoredMask.startPoint, CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(restoredMask.endPoint, CGPoint(x: 1, y: 0.5))

        view.updateText(shortText)
        view.layout()
        XCTAssertFalse(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertEqual(view.scrollOverflow, 0, accuracy: 0.001)
        XCTAssertNil(view.layer?.mask)
        XCTAssertEqual(view.accountLabel.frame.minX, view.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(view.accountLabel.frame.width, view.bounds.width, accuracy: 0.001)

        view.updateText(longText)
        view.layout()
        XCTAssertTrue(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertGreaterThan(view.scrollOverflow, 0)
    }

    func testAccountMarqueeStartsAnimationWhenAttachedAndFadesOnlyAfterActualOffset() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 18))
        let view = AccountMarqueeView(
            text: String(repeating: "long-account-name-", count: 8),
            font: .systemFont(ofSize: 13),
            textColor: .secondaryLabelColor,
            frame: container.bounds
        )
        defer { view.removeFromSuperview() }

        container.addSubview(view)

        XCTAssertTrue(view.isScrollable)
        XCTAssertNotNil(view.accountLabel.layer?.animation(forKey: AccountMarqueeView.animationKey))
        XCTAssertEqual(view.scrollOffset, 0, accuracy: 0.001)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertNil(view.layer?.mask)
        XCTAssertFalse(
            AccountMarqueeScrollState(
                offset: 0,
                overflow: view.scrollOverflow
            ).isActive
        )
        XCTAssertFalse(
            AccountMarqueeScrollState(
                offset: -0.25,
                overflow: view.scrollOverflow
            ).isActive
        )

        view.applyScrollOffsetForTesting(-1)
        XCTAssertTrue(view.isScrolling)
        XCTAssertEqual(view.scrollOffset, -1, accuracy: 0.001)
        XCTAssertTrue(view.showsEdgeFade)
        XCTAssertNotNil(view.layer?.mask as? CAGradientLayer)

        view.applyScrollOffsetForTesting(0)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertNil(view.layer?.mask)
    }

    func testAccountMarqueeSamplesPresentationOffsetDuringRealAnimation() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 128, height: 18),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        let view = AccountMarqueeView(
            text: "account-alpha-20260827-singapore-long-identifier-beta-usage-quota-gamma-openai-official-delta-window-resize-epsilon-manual-check@example-super-long-domain.test",
            font: .systemFont(ofSize: 13),
            textColor: .secondaryLabelColor,
            frame: NSRect(x: 0, y: 0, width: 128, height: 18)
        )
        defer {
            view.removeFromSuperview()
            window.orderOut(nil)
        }

        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        window.displayIfNeeded()

        XCTAssertTrue(view.isScrollable)
        XCTAssertEqual(view.scrollOffset, 0, accuracy: 0.001)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)

        let animation = try XCTUnwrap(
            view.accountLabel.layer?.animation(
                forKey: AccountMarqueeView.animationKey
            ) as? CAKeyframeAnimation
        )
        let endpoint = try XCTUnwrap(animation.values?[2] as? NSNumber)
        XCTAssertEqual(endpoint.doubleValue, -Double(view.scrollDistance), accuracy: 0.001)

        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertLessThan(
            view.scrollOffset,
            -AccountMarqueeScrollState.activationThreshold
        )
        XCTAssertTrue(view.isScrolling)
        XCTAssertTrue(view.showsEdgeFade)
        XCTAssertNotNil(view.layer?.mask as? CAGradientLayer)

        let activeOffset = view.scrollOffset
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotEqual(view.scrollOffset, activeOffset, accuracy: 0.001)
    }

    func testAccountMarqueeSpeedsUpForLongerOverflowWithConcaveCurve() {
        let shortSpeed = AccountMarqueeView.scrollSpeed(forOverflow: 120)
        let mediumSpeed = AccountMarqueeView.scrollSpeed(forOverflow: 480)
        let longSpeed = AccountMarqueeView.scrollSpeed(forOverflow: 1_200)
        let extremeSpeed = AccountMarqueeView.scrollSpeed(forOverflow: 12_000)

        XCTAssertGreaterThan(mediumSpeed, shortSpeed)
        XCTAssertGreaterThan(longSpeed, mediumSpeed)
        XCTAssertLessThan(
            longSpeed - mediumSpeed,
            mediumSpeed - shortSpeed
        )
        XCTAssertGreaterThan(extremeSpeed, longSpeed)
        XCTAssertLessThanOrEqual(extremeSpeed, 180)

        let shortAnimation = AccountMarqueeView.scrollAnimation(forOverflow: 120)
        let longAnimation = AccountMarqueeView.scrollAnimation(forOverflow: 1_200)
        XCTAssertGreaterThan(longAnimation.duration, shortAnimation.duration)
        XCTAssertEqual(longAnimation.repeatCount, .infinity)
    }

    func testLocalizedOverviewQuotaAndResetReuseAccountMarqueeLayout() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .german

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                openOpenCodex: {},
                quit: {},
                switchProvider: { _ in },
                switchOpenCodexPreference: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let input = StatusItemController.MenuInput(
            openCodexCards: [],
            openCodexState: nil,
            openCodexSwitchInFlight: false,
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: OpenAIAccountPresentation(
                email: "person@example.com",
                subscription: .proFiveX
            ),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showOpenCodexMenu: false,
            showStatusMenu: false
        )
        let shortQuota = "7-Tage-Kontingent"
        let shortResetValue = "6d14"
        let shortReset = shortResetValue
        let longQuota = String(repeating: "7-Tage-Kontingent ", count: 4)
        let longReset = String(repeating: "6d14 ", count: 12)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let baselineFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true
        )
        controller.start(
            snapshot: .official("OpenAI Official", 77, shortQuota, shortResetValue, date),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let shortOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let shortMarquees = shortOverview.subviews.compactMap { $0 as? AccountMarqueeView }
        let shortQuotaView = try XCTUnwrap(
            shortMarquees.first { $0.accountLabel.stringValue == shortQuota }
        )
        let shortResetView = try XCTUnwrap(
            shortMarquees.first { $0.accountLabel.stringValue.contains(shortReset) }
        )
        XCTAssertFalse(shortQuotaView.isScrollable)
        XCTAssertFalse(shortQuotaView.showsEdgeFade)
        XCTAssertFalse(shortResetView.isScrollable)
        XCTAssertFalse(shortResetView.showsEdgeFade)
        XCTAssertGreaterThan(shortQuotaView.bounds.width, baselineFrames.quotaDetail.width)
        XCTAssertGreaterThan(shortResetView.bounds.width, try XCTUnwrap(baselineFrames.reset).width)
        XCTAssertEqual(shortQuotaView.accountLabel.frame.width, shortQuotaView.bounds.width)
        XCTAssertEqual(shortResetView.accountLabel.frame.width, shortResetView.bounds.width)

        controller.update(
            snapshot: .official("OpenAI Official", 78, longQuota, longReset, date),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let marquees = overview.subviews.compactMap { $0 as? AccountMarqueeView }
        let quota = try XCTUnwrap(
            marquees.first { $0.accountLabel.stringValue == longQuota }
        )
        let reset = try XCTUnwrap(
            marquees.first { $0.accountLabel.stringValue.contains(longReset) }
        )
        XCTAssertTrue(quota.isScrollable)
        XCTAssertTrue(reset.isScrollable)
        XCTAssertGreaterThan(quota.accountLabel.frame.width, quota.bounds.width)
        XCTAssertGreaterThan(reset.accountLabel.frame.width, reset.bounds.width)

        let amount = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first { $0.stringValue == "78%" }
        )
        let frames = baselineFrames
        let amountTextWidth = AccountMarqueeView.textWidth(
            of: amount.stringValue,
            font: try XCTUnwrap(amount.font)
        )
        let safeAmountMinX = max(amount.frame.minX, amount.frame.maxX - amountTextWidth)
        let expectedRightEdge = safeAmountMinX
        XCTAssertEqual(quota.frame.minX, frames.quotaDetail.minX)
        XCTAssertEqual(quota.frame.minY, frames.quotaDetail.minY)
        XCTAssertEqual(quota.frame.height, frames.quotaDetail.height)
        XCTAssertGreaterThan(quota.frame.width, frames.quotaDetail.width)
        XCTAssertEqual(quota.frame.maxX, expectedRightEdge, accuracy: 0.5)
        let resetFrame = try XCTUnwrap(frames.reset)
        XCTAssertEqual(reset.frame.minX, resetFrame.minX)
        XCTAssertEqual(reset.frame.minY, resetFrame.minY)
        XCTAssertEqual(reset.frame.height, resetFrame.height)
        XCTAssertGreaterThan(reset.frame.width, resetFrame.width)
        XCTAssertEqual(reset.frame.maxX, expectedRightEdge, accuracy: 0.5)
    }

    func testOfficialCodexMenuCardRendersIndependentFiveHourAndSevenDayRows() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                openOpenCodex: {},
                quit: {},
                switchProvider: { _ in },
                switchOpenCodexPreference: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let input = StatusItemController.MenuInput(
            openCodexCards: [],
            openCodexState: nil,
            openCodexSwitchInFlight: false,
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: OpenAIAccountPresentation(email: "person@example.com", subscription: .proFiveX),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showOpenCodexMenu: false,
            showStatusMenu: false
        )
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let date = Date()
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2d0h",
                durationSeconds: 18_000,
                resetAt: date.addingTimeInterval(2 * 86_400)
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota2),
                daysText: tr(.keyResponseParsers7Days4),
                reset: "7d0h",
                durationSeconds: 604_800,
                resetAt: date.addingTimeInterval(7 * 86_400)
            )
        ]

        controller.start(
            snapshot: .official(
                "OpenAI Official",
                45,
                tr(.keyResponseParsers7DayQuota2),
                "1h30m",
                date,
                windows: windows
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let expectedResetTexts = windows.map { $0.resetDisplayText()! }
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows
        )
        XCTAssertEqual(overview.bounds.size, frames.cardSize)

        let progressViews = overview.subviews.compactMap { $0 as? QuotaProgressView }
        XCTAssertEqual(progressViews.map(\.percentage), [80, 45])
        XCTAssertEqual(
            progressViews.map(\.frame),
            frames.quotaRows.map(\.progress)
        )
        let percentageLabels = allControls(of: overview, as: NSTextField.self)
            .filter { $0.stringValue == "80%" || $0.stringValue == "45%" }
        XCTAssertEqual(percentageLabels.count, 2)
        let expectedAmountTraits = NSFont.monospacedDigitSystemFont(
            ofSize: OpenCodexCardLayout.quotaAmountPointSize,
            weight: .semibold
        ).fontDescriptor.symbolicTraits.rawValue
        XCTAssertTrue(
            percentageLabels.allSatisfy {
                ($0.font?.pointSize ?? 0) == OpenCodexCardLayout.quotaAmountPointSize
                    && ($0.font?.fontDescriptor.symbolicTraits.rawValue ?? 0) == expectedAmountTraits
                    && $0.frame.height == OpenCodexCardLayout.quotaAmountHeight
            }
        )

        let quotaViews = overview.subviews.compactMap { $0 as? AccountMarqueeView }
            .filter {
                let value = $0.accountLabel.stringValue
                return value == tr(.keyResponseParsers5HourQuota)
                    || value == tr(.keyResponseParsers7DayQuota2)
                    || expectedResetTexts.contains(value)
            }
        XCTAssertEqual(
            quotaViews.map { $0.accountLabel.stringValue },
            [
                tr(.keyResponseParsers5HourQuota),
                expectedResetTexts[0],
                tr(.keyResponseParsers7DayQuota2),
                expectedResetTexts[1]
            ]
        )
        XCTAssertTrue(expectedResetTexts.allSatisfy { $0.contains(" · ") })
        XCTAssertNotEqual(expectedResetTexts[0], expectedResetTexts[1])
        let expectedBaseFrames = [
            frames.quotaRows[0].quotaDetail,
            frames.quotaRows[0].reset,
            frames.quotaRows[1].quotaDetail,
            frames.quotaRows[1].reset
        ]
        for (index, (view, expected)) in zip(quotaViews, expectedBaseFrames).enumerated() {
            let isReset = index == 1 || index == 3
            XCTAssertEqual(view.frame.minX, expected.minX)
            XCTAssertEqual(view.frame.minY, expected.minY)
            XCTAssertEqual(view.frame.height, expected.height)
            XCTAssertGreaterThanOrEqual(view.frame.width, expected.width)
            XCTAssertEqual(
                view.accountLabel.font?.pointSize ?? 0,
                isReset
                    ? OpenCodexCardLayout.quotaResetPointSize
                    : OpenCodexCardLayout.quotaDetailPointSize
            )
        }
        XCTAssertTrue(quotaViews.allSatisfy { $0.accountLabel.lineBreakMode == .byClipping })
        let expectedDetailTraits = NSFont.systemFont(
            ofSize: OpenCodexCardLayout.quotaDetailPointSize,
            weight: .medium
        ).fontDescriptor.symbolicTraits.rawValue
        let expectedResetTraits = NSFont.systemFont(
            ofSize: OpenCodexCardLayout.quotaResetPointSize,
            weight: .regular
        ).fontDescriptor.symbolicTraits.rawValue
        for (index, view) in quotaViews.enumerated() {
            let expectedTraits = index == 1 || index == 3
                ? expectedResetTraits
                : expectedDetailTraits
            XCTAssertEqual(
                view.accountLabel.font?.fontDescriptor.symbolicTraits.rawValue ?? 0,
                expectedTraits
            )
        }
        XCTAssertEqual(
            allControls(of: overview, as: NSTextField.self)
                .filter { $0.stringValue == "80%" || $0.stringValue == "45%" }
                .map(\.stringValue),
            ["80%", "45%"]
        )
        XCTAssertLessThanOrEqual(
            frames.quotaRows[0].quotaDetail.maxX,
            overview.bounds.maxX - 14
        )
        XCTAssertLessThanOrEqual(
            frames.quotaRows[1].quotaDetail.maxX,
            overview.bounds.maxX - 14
        )
        XCTAssertTrue(quotaViews.allSatisfy { $0.frame.maxX <= overview.bounds.maxX })

        let longWindows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: String(repeating: windows[0].label + " ", count: 8),
                daysText: windows[0].daysText,
                reset: String(repeating: "2d0h ", count: 8),
                durationSeconds: windows[0].durationSeconds
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: String(repeating: windows[1].label + " ", count: 8),
                daysText: windows[1].daysText,
                reset: String(repeating: "7d0h ", count: 8),
                durationSeconds: windows[1].durationSeconds
            )
        ]
        controller.update(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: longWindows
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        let longOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let longQuotaViews = longOverview.subviews.compactMap { $0 as? AccountMarqueeView }
            .filter { view in
                let value = view.accountLabel.stringValue
                return value == longWindows[0].label
                    || value == longWindows[1].label
                    || value.contains("2d0h")
                    || value.contains("7d0h")
            }
        XCTAssertEqual(longQuotaViews.count, 4)
        XCTAssertTrue(longQuotaViews.allSatisfy { $0.isScrollable })
        XCTAssertTrue(longQuotaViews.allSatisfy { $0.frame.maxX <= longOverview.bounds.maxX })

        let reserve = LunaReserveQuota(status: .available, remaining: 45, reset: "1h30m")
        controller.update(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: windows,
                lunaReserve: reserve
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        let reserveOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let reserveFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesLunaReserve: true
        )
        XCTAssertEqual(reserveOverview.bounds.size, reserveFrames.cardSize)
        XCTAssertEqual(
            reserveOverview.subviews.compactMap { $0 as? QuotaProgressView }.map(\.percentage),
            [80, 45, 45]
        )
        XCTAssertNotNil(
            reserveOverview.subviews.compactMap { $0 as? AccountMarqueeView }.first {
                $0.accountLabel.stringValue == tr(.keyLunaReserveTitleStatusValue, arguments: [
                    tr(.keyLunaReserveTitle),
                    tr(.keyLunaReserveStatusAvailable)
                ])
            }
        )
        XCTAssertNotNil(
            reserveOverview.subviews.compactMap { $0 as? AccountMarqueeView }.first {
                $0.accountLabel.stringValue == reserve.resetText
            }
        )
    }

    func testOpenCodexAndCCSwitchMenuItemsAreIndependentAndOpenCodexActivatesOnce() throws {
        for openCodexIsCurrent in [true, false] {
            for showOpenCodexMenu in [true, false] {
                for showOpenCCSwitchMenu in [true, false] {
                    var activationCount = 0
                    let controller = StatusItemController(
                        actions: StatusItemController.Actions(
                            manualRefresh: {},
                            openDashboard: {},
                            openChatGPT: {},
                            openCCSwitch: {},
                            openOpenCodex: { activationCount += 1 },
                            quit: {},
                            switchProvider: { _ in },
                            switchOpenCodexPreference: { _ in },
                            openProviderWebsite: {},
                            openStatusLink: { _ in },
                            iconChanged: { _ in }
                        )
                    )
                    defer { controller.teardown() }

                    let choices = [
                        ProviderChoice(
                            id: "opencodex",
                            name: "OpenCodex",
                            isCurrent: openCodexIsCurrent
                        ),
                        ProviderChoice(
                            id: "other",
                            name: "Other Provider",
                            isCurrent: !openCodexIsCurrent
                        )
                    ]
                    controller.start(
                        snapshot: .placeholder,
                        refreshDate: nil,
                        menuInput: StatusItemController.MenuInput(
                            openCodexCards: [],
                            openCodexState: nil,
                            openCodexSwitchInFlight: false,
                            choices: choices,
                            quickSwitchSummaries: [:],
                            activeClient: .claude,
                            openAIAccount: nil,
                            statusLinks: [
                                StatusLink(title: "Status", url: "https://status.example")
                            ],
                            showQuickSwitchMenu: true,
                            showOpenChatGPTMenu: true,
                            showOpenCCSwitchMenu: showOpenCCSwitchMenu,
                            showOpenCodexMenu: showOpenCodexMenu,
                            showStatusMenu: true
                        ),
                        settings: StatusItemController.MenuBarSettings(
                            showIcon: true,
                            showAmount: true,
                            showReset: true,
                            horizontalPadding: 6,
                            keepMenuOpenAfterRefresh: true
                        )
                    )

                    XCTAssertEqual(
                        controller.menuItemsForTesting.filter { $0.title.contains("OpenCodex") }.count,
                        showOpenCodexMenu ? 1 : 0
                    )
                    if showOpenCodexMenu {
                        let openItem = try XCTUnwrap(
                            controller.menuItemsForTesting.first {
                                $0.title.contains("OpenCodex")
                            }
                        )
                        XCTAssertTrue(openItem.isEnabled)
                        let target = try XCTUnwrap(openItem.target as? NSObject)
                        _ = target.perform(openItem.action, with: openItem)
                        XCTAssertEqual(activationCount, 1)
                    } else {
                        XCTAssertEqual(activationCount, 0)
                    }
                    XCTAssertEqual(
                        controller.menuItemsForTesting.contains {
                            $0.title == "打开 CC Switch" || $0.title == "Open CC Switch"
                        },
                        showOpenCCSwitchMenu
                    )

                    let statusMenuItem = try XCTUnwrap(
                        controller.menuItemsForTesting.first {
                            $0.title == "查看状态" || $0.title == "View Status"
                        }
                    )
                    XCTAssertEqual(statusMenuItem.submenu?.items.map(\.title), ["Status"])
                }
            }
        }
    }

    private func findStatusLinksEditor(in view: NSView) -> StatusLinksEditorHostingView? {
        if let editor = view as? StatusLinksEditorHostingView {
            return editor
        }
        for child in view.subviews {
            if let editor = findStatusLinksEditor(in: child) {
                return editor
            }
        }
        return nil
    }

    private func findStatusLinksEditors(in view: NSView) -> [StatusLinksEditorHostingView] {
        var result: [StatusLinksEditorHostingView] = []
        if let editor = view as? StatusLinksEditorHostingView {
            result.append(editor)
        }
        for child in view.subviews {
            result.append(contentsOf: findStatusLinksEditors(in: child))
        }
        return result
    }

    private func layoutDescendants(of view: NSView) {
        view.layoutSubtreeIfNeeded()
        for child in view.subviews {
            layoutDescendants(of: child)
        }
    }

    private func firstDescendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        for child in view.subviews {
            if let match = child as? T {
                return match
            }
            if let match = firstDescendant(of: child, as: type) {
                return match
            }
        }
        return nil
    }

    private func ancestors(of view: NSView) -> [NSView] {
        var result: [NSView] = []
        var current = view.superview
        while let ancestor = current {
            result.append(ancestor)
            current = ancestor.superview
        }
        return result
    }

    private func menuPage(in window: NSWindow) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        func containsScrollView(_ view: NSView) -> Bool {
            if view is NSScrollView { return true }
            return view.subviews.contains(where: containsScrollView)
        }
        return contentView.subviews
            .flatMap { $0.subviews }
            .first(where: containsScrollView)
    }

    private func firstControl<T: NSView>(
        of view: NSView,
        as type: T.Type,
        where predicate: (T) -> Bool
    ) -> T? {
        for child in view.subviews {
            if let match = child as? T, predicate(match) {
                return match
            }
            if let match = firstControl(of: child, as: type, where: predicate) {
                return match
            }
        }
        return nil
    }

    private func allControls<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var matches: [T] = []
        for child in view.subviews {
            if let match = child as? T {
                matches.append(match)
            }
            matches.append(contentsOf: allControls(of: child, as: type))
        }
        return matches
    }
}
