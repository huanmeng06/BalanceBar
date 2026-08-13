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
    func testMenuPageKeepsStatusLinksEditorWhenMenuDisplayIsDisabled() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
        }
        defaults.set(false, forKey: "showStatusMenu")

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26.db"))
        )
        let page = appDelegate.dashboardPageForTesting(.menu)

        XCTAssertNotNil(findStatusLinksEditor(in: page))
    }

    func testMenuPageLaysOutReachableStatusLinksEditorForBothMenuVisibilityStates() throws {
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

        for showStatusMenu in [false, true] {
            defaults.set(showStatusMenu, forKey: "showStatusMenu")
            defaults.removeObject(forKey: "statusLinks")
            let appDelegate = AppDelegate(
                repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26-layout.db"))
            )
            defer { appDelegate.teardownDashboardForTesting() }
            let window = try XCTUnwrap(appDelegate.dashboardWindowForTesting(showing: .menu))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let page = try XCTUnwrap(
                window.contentView?.subviews
                    .flatMap { $0.subviews }
                    .first { $0.subviews.contains(where: { $0 is NSScrollView }) }
            )
            layoutDescendants(of: window.contentView!)

            let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))
            let documentView = try XCTUnwrap(scrollView.documentView)
            let editor = try XCTUnwrap(findStatusLinksEditor(in: page))
            let card = try XCTUnwrap(
                ancestors(of: editor).first { $0.layer?.cornerRadius == 18 }
            )

            XCTAssertFalse(editor.isHidden, "Status Links editor is hidden for showStatusMenu=\(showStatusMenu)")
            XCTAssertGreaterThan(editor.frame.width, 0)
            XCTAssertEqual(editor.frame.height, editor.layoutHeight, accuracy: 1)
            XCTAssertEqual(editor.subviews.count, 1, "Status Links host was torn down after page creation")
            let hostingView = try XCTUnwrap(editor.subviews.first)
            XCTAssertGreaterThan(hostingView.frame.width, 0)
            XCTAssertGreaterThan(hostingView.frame.height, 0)

            let editorRectInCard = editor.convert(editor.bounds, to: card)
            XCTAssertTrue(
                card.bounds.insetBy(dx: -1, dy: -1).contains(editorRectInCard),
                "Status Links editor is clipped by its card for showStatusMenu=\(showStatusMenu): editor=\(editorRectInCard), card=\(card.bounds)"
            )

            let editorRectInDocument = editor.convert(editor.bounds, to: documentView)
            XCTAssertTrue(
                documentView.bounds.insetBy(dx: -1, dy: -1).contains(editorRectInDocument),
                "Status Links editor is outside the scroll document for showStatusMenu=\(showStatusMenu): editor=\(editorRectInDocument), document=\(documentView.bounds)"
            )
            XCTAssertGreaterThan(
                documentView.bounds.height,
                scrollView.contentView.bounds.height,
                "Status Links editor must be reachable by scrolling for showStatusMenu=\(showStatusMenu)"
            )

            let expectedIdentifiers = [
                "statusLinks.title",
                "statusLinks.reset",
                "statusLinks.add"
            ] + (0..<editor.rowCount).flatMap { index in
                [
                    "statusLinks.name.\(index)",
                    "statusLinks.url.\(index)",
                    "statusLinks.remove.\(index)"
                ]
            }
            let accessibilityElements = accessibilityDescendants(of: hostingView)
            let cardFrameOnScreen = window.convertToScreen(card.convert(card.bounds, to: nil))
            for identifier in expectedIdentifiers {
                let matches = accessibilityElements.filter {
                    $0.accessibilityIdentifier?() == identifier
                }
                XCTAssertEqual(
                    matches.count,
                    1,
                    "Expected one real Status Links control with identifier \(identifier) for showStatusMenu=\(showStatusMenu)"
                )
                let control: NSAccessibilityElementProtocol = try XCTUnwrap(matches.first)
                let controlFrame = control.accessibilityFrame()
                XCTAssertGreaterThan(controlFrame.width, 0, identifier)
                XCTAssertGreaterThan(controlFrame.height, 0, identifier)
                XCTAssertTrue(
                    cardFrameOnScreen.insetBy(dx: -1, dy: -1).contains(controlFrame),
                    "\(identifier) is clipped by the Status Links card"
                )
            }
        }
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

    private func accessibilityDescendants(of view: NSView) -> [NSAccessibilityElementProtocol] {
        let children = (view.accessibilityChildren() ?? []).compactMap {
            $0 as? NSAccessibilityElementProtocol
        }
        return children + view.subviews.flatMap(accessibilityDescendants(of:))
    }
}
