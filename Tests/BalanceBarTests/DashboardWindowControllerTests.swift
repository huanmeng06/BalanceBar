import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardWindowControllerTests: XCTestCase {
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
        defer { appDelegate.teardownDashboardForTesting() }
        let page = appDelegate.dashboardPageForTesting(.menu)

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
        defer { appDelegate.teardownDashboardForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardWindowForTesting(showing: .menu))
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

    func testProductionMenuAddSmoothlyFollowsStatusLinksToDocumentBottom() throws {
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
        defer { appDelegate.teardownDashboardForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardWindowForTesting(showing: .menu))
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
        let initialDocumentHeight = documentView.bounds.height
        var sampledOffsets: [CGFloat] = [initialOffset]
        var sampledTitleY: [CGFloat] = [initialTitleY]
        var sampledCardTop: [CGFloat] = [cardTop()]

        appDelegate.addStatusLinkForTesting()

        let deadline = Date().addingTimeInterval(0.34)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            sampledOffsets.append(visibleOffset())
            sampledCardTop.append(cardTop())
            sampledTitleY.append(try XCTUnwrap(editor.viewportAnchorY(
                identifier: NSUserInterfaceItemIdentifier("statusLinks.title.anchor"),
                in: scrollView.contentView
            )))
        }

        XCTAssertEqual(editor.rowCount, 3)
        XCTAssertEqual(editor.renderedRowCount, 3)
        XCTAssertGreaterThan(documentView.bounds.height, initialDocumentHeight)
        XCTAssertTrue(editor.hostedContentIsWithinRevealBounds)
        let finalGeometry = DashboardScrollGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: scrollView.contentView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        XCTAssertEqual(visibleOffset(), finalGeometry.maximumOffset, accuracy: 0.5)
        XCTAssertGreaterThan(visibleOffset(), initialOffset + 20)
        for (previous, current) in zip(sampledOffsets, sampledOffsets.dropFirst()) {
            XCTAssertGreaterThanOrEqual(current, previous - 0.5)
            XCTAssertLessThanOrEqual(current - previous, 10)
        }
        for (previous, current) in zip(sampledTitleY, sampledTitleY.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(current - previous), 10)
        }
        for (previous, current) in zip(sampledCardTop, sampledCardTop.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(current - previous), 10)
        }
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
        defer { appDelegate.teardownDashboardForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardWindowForTesting(showing: .menu))
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
        defer { appDelegate.teardownDashboardForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardWindowForTesting(showing: .menu))
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
            statusLinks: [
                StatusLink(title: "Status", url: "https://status.example")
            ],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
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
            statusLinks: [
                StatusLink(title: "Status", url: "https://status.example")
            ],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
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

    func testOpenCodexMenuItemActivatesOnceForSelectedAndUnselectedStates() throws {
        for openCodexIsCurrent in [true, false] {
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
                    statusLinks: [
                        StatusLink(title: "Status", url: "https://status.example")
                    ],
                    showQuickSwitchMenu: true,
                    showOpenChatGPTMenu: true,
                    showOpenCCSwitchMenu: true,
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

            let openItem = try XCTUnwrap(
                controller.menuItemsForTesting.first {
                    $0.title.contains("OpenCodex")
                }
            )
            XCTAssertTrue(openItem.isEnabled)
            let target = try XCTUnwrap(openItem.target as? NSObject)
            _ = target.perform(openItem.action, with: openItem)
            XCTAssertEqual(activationCount, 1)
            XCTAssertEqual(
                controller.menuItemsForTesting.filter { $0.title.contains("OpenCodex") }.count,
                1
            )

            let statusMenuItem = try XCTUnwrap(
                controller.menuItemsForTesting.first {
                    $0.title == "查看状态" || $0.title == "View Status"
                }
            )
            XCTAssertEqual(statusMenuItem.submenu?.items.map(\.title), ["Status"])
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
        window.contentView?.subviews
            .flatMap { $0.subviews }
            .first { $0.subviews.contains(where: { $0 is NSScrollView }) }
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
}
