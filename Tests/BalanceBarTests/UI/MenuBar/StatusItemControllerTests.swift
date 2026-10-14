import AppKit
import XCTest
@testable import BalanceBar

final class StatusItemControllerTests: XCTestCase {
    /// The status item button must carry an image at all times (see
    /// `StatusItemController.placeholderButtonImage`), and that image must
    /// stay empty so it renders no pixels and does not affect item layout.
    func testPlaceholderButtonImageIsEmptySoItRendersNoPixels() {
        let image = StatusItemController.placeholderButtonImage
        XCTAssertEqual(image.size, .zero)
        XCTAssertTrue(image.representations.isEmpty)
        XCTAssertNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    @MainActor
    func testRightClickOpenAgentOpensCurrentAgentWithoutOpeningCCSwitch() {
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openAgent)
        )
        XCTAssertEqual(controller.rightClickActionForTesting, .openAgent)
        controller.handleConfiguredRightClickForTesting()
        XCTAssertEqual(agentOpens, 1)
        XCTAssertEqual(ccSwitchOpens, 0)
    }

    @MainActor
    func testRightClickOpenCCSwitchOpensCCSwitchWithoutOpeningAgent() {
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openCCSwitch)
        )
        controller.handleConfiguredRightClickForTesting()
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 1)
    }

    @MainActor
    func testRightClickMatchLeftClickDoesNotOpenAgentOrCCSwitch() {
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .matchLeftClick)
        )
        controller.handleConfiguredRightClickForTesting()
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)
    }

    @MainActor
    func testRightClickOpenMainWindowOpensDashboardWithoutOpeningAgentOrCCSwitch() {
        var dashboardOpens = 0
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openDashboard: { dashboardOpens += 1 },
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openMainWindow)
        )
        controller.handleConfiguredRightClickForTesting()
        XCTAssertEqual(dashboardOpens, 1)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)
    }

    @MainActor
    func testRightClickOpenMainWindowHighlightsOnMouseDownAndOpensOnMouseUp() {
        var dashboardOpens = 0
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openDashboard: { dashboardOpens += 1 },
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openMainWindow)
        )
        controller.handleStatusItemRightMouseDownForTesting()
        XCTAssertTrue(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertEqual(dashboardOpens, 0)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)

        controller.handleStatusItemRightMouseUpForTesting()
        XCTAssertFalse(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(dashboardOpens, 1)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)
        XCTAssertTrue(controller.isStatusMenuBoundForTesting)
    }

    @MainActor
    func testRightClickOpenMainWindowDetachesStatusMenuUntilMouseUp() {
        var dashboardOpens = 0
        let controller = makeController(openDashboard: { dashboardOpens += 1 })
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openMainWindow)
        )
        XCTAssertTrue(controller.isStatusMenuBoundForTesting)

        controller.handleStatusItemRightMouseDownForTesting()
        XCTAssertFalse(controller.isStatusMenuBoundForTesting)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertEqual(dashboardOpens, 0)

        controller.handleStatusItemRightMouseUpForTesting()
        XCTAssertEqual(dashboardOpens, 1)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertTrue(controller.isStatusMenuBoundForTesting)
    }

    @MainActor
    func testRapidRightClickOpenMainWindowDoesNotPresentTheStatusMenu() {
        var dashboardOpens = 0
        let controller = makeController(openDashboard: { dashboardOpens += 1 })
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openMainWindow)
        )
        for _ in 0..<3 {
            controller.handleStatusItemRightMouseDownForTesting()
            XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
            controller.handleStatusItemRightMouseUpForTesting()
        }
        XCTAssertEqual(dashboardOpens, 3)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertTrue(controller.isStatusMenuBoundForTesting)
    }

    @MainActor
    func testRightClickMatchLeftClickPresentsTheStatusItemMenuOnMouseDown() {
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .matchLeftClick)
        )
        controller.handleStatusItemRightMouseDownForTesting()
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 1)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)
    }

    @MainActor
    func testRightClickOpenAgentHighlightsOnMouseDownAndOpensOnMouseUp() {
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openAgent)
        )
        controller.handleStatusItemRightMouseDownForTesting()
        XCTAssertTrue(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)

        controller.handleStatusItemRightMouseUpForTesting()
        XCTAssertFalse(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(agentOpens, 1)
        XCTAssertEqual(ccSwitchOpens, 0)
    }

    @MainActor
    func testRightClickOpenCCSwitchHighlightsOnMouseDownAndOpensOnMouseUp() {
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openCCSwitch)
        )
        controller.handleStatusItemRightMouseDownForTesting()
        XCTAssertTrue(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)

        controller.handleStatusItemRightMouseUpForTesting()
        XCTAssertFalse(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 1)
    }

    @MainActor
    func testReversedClicksOpenConfiguredActionOnLeftAndMenuOnRight() {
        var dashboardOpens = 0
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openDashboard: { dashboardOpens += 1 },
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(
                rightClickAction: .openMainWindow,
                reverseMouseButtons: true
            )
        )
        XCTAssertTrue(controller.areMouseButtonsReversedForTesting)

        controller.handleStatusItemLeftMouseDownForTesting()
        XCTAssertTrue(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertEqual(dashboardOpens, 0)

        controller.handleStatusItemLeftMouseUpForTesting()
        XCTAssertFalse(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(dashboardOpens, 1)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)

        controller.handleStatusItemRightMouseDownForTesting()
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 1)
        XCTAssertEqual(dashboardOpens, 1)
        controller.handleStatusItemRightMouseUpForTesting()
        XCTAssertEqual(dashboardOpens, 1)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)
    }

    @MainActor
    func testReverseIsIgnoredWhenRightClickMatchesLeftClick() {
        var dashboardOpens = 0
        let controller = makeController(
            openDashboard: { dashboardOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(
                rightClickAction: .matchLeftClick,
                reverseMouseButtons: true
            )
        )
        XCTAssertTrue(controller.reverseMouseButtonsForTesting)
        XCTAssertFalse(controller.areMouseButtonsReversedForTesting)

        controller.handleStatusItemLeftMouseDownForTesting()
        XCTAssertFalse(controller.statusItemButtonIsHighlightedForTesting)
        controller.handleStatusItemLeftMouseUpForTesting()
        XCTAssertEqual(dashboardOpens, 0)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)

        controller.handleStatusItemRightMouseDownForTesting()
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 1)
        XCTAssertEqual(dashboardOpens, 0)
    }

    @MainActor
    func testReversedRightClickIsRewrittenToANativeLeftClick() {
        let controller = makeController()
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(
                rightClickAction: .openMainWindow,
                reverseMouseButtons: true
            )
        )
        let down = makeMouseEvent(.rightMouseDown)
        let rewrittenDown = controller.rewriteReversedRightClickEventForTesting(down)
        XCTAssertEqual(rewrittenDown?.type, .leftMouseDown)

        let up = makeMouseEvent(.rightMouseUp)
        let rewrittenUp = controller.rewriteReversedRightClickEventForTesting(up)
        XCTAssertEqual(rewrittenUp?.type, .leftMouseUp)
    }

    @MainActor
    func testRightClickIsNotRewrittenWhenReverseIsOff() {
        let controller = makeController()
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openMainWindow)
        )
        XCTAssertNil(
            controller.rewriteReversedRightClickEventForTesting(
                makeMouseEvent(.rightMouseDown)
            )
        )
    }

    @MainActor
    func testControlClickOpenMainWindowHighlightsOnMouseDownAndOpensOnMouseUp() {
        var dashboardOpens = 0
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openDashboard: { dashboardOpens += 1 },
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openMainWindow)
        )
        controller.handleStatusItemControlClickMouseDownForTesting()
        XCTAssertTrue(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertEqual(dashboardOpens, 0)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)

        controller.handleStatusItemControlClickMouseUpForTesting()
        XCTAssertFalse(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(dashboardOpens, 1)
        XCTAssertEqual(agentOpens, 0)
        XCTAssertEqual(ccSwitchOpens, 0)
        XCTAssertTrue(controller.isStatusMenuBoundForTesting)
    }

    @MainActor
    func testControlClickOpenMainWindowDetachesStatusMenuUntilMouseUp() {
        var dashboardOpens = 0
        let controller = makeController(openDashboard: { dashboardOpens += 1 })
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openMainWindow)
        )
        XCTAssertTrue(controller.isStatusMenuBoundForTesting)

        controller.handleStatusItemControlClickMouseDownForTesting()
        XCTAssertFalse(controller.isStatusMenuBoundForTesting)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertEqual(dashboardOpens, 0)

        controller.handleStatusItemControlClickMouseUpForTesting()
        XCTAssertEqual(dashboardOpens, 1)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertTrue(controller.isStatusMenuBoundForTesting)
    }

    @MainActor
    func testControlClickOpenAgentHighlightsOnMouseDownAndOpensOnMouseUp() {
        var agentOpens = 0
        var ccSwitchOpens = 0
        let controller = makeController(
            openChatGPT: { agentOpens += 1 },
            openCCSwitch: { ccSwitchOpens += 1 }
        )
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openAgent)
        )
        controller.handleStatusItemControlClickMouseDownForTesting()
        XCTAssertTrue(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertEqual(agentOpens, 0)

        controller.handleStatusItemControlClickMouseUpForTesting()
        XCTAssertEqual(agentOpens, 1)
        XCTAssertEqual(ccSwitchOpens, 0)
    }

    @MainActor
    func testControlClickIsPassedThroughWhenRightClickMatchesLeftClick() {
        var dashboardOpens = 0
        let controller = makeController(openDashboard: { dashboardOpens += 1 })
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .matchLeftClick)
        )
        let down = makeMouseEvent(.leftMouseDown, modifiers: .control)
        XCTAssertTrue(controller.handleStatusItemEventForTesting(down) === down)
        controller.handleStatusItemControlClickMouseDownForTesting()
        XCTAssertFalse(controller.statusItemButtonIsHighlightedForTesting)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
        XCTAssertEqual(dashboardOpens, 0)
    }

    @MainActor
    func testControlClickIsPassedThroughWhenButtonsAreReversed() {
        var dashboardOpens = 0
        let controller = makeController(openDashboard: { dashboardOpens += 1 })
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(
                rightClickAction: .openMainWindow,
                reverseMouseButtons: true
            )
        )
        let down = makeMouseEvent(.leftMouseDown, modifiers: .control)
        XCTAssertTrue(controller.handleStatusItemEventForTesting(down) === down)
        controller.handleStatusItemControlClickMouseDownForTesting()
        XCTAssertEqual(dashboardOpens, 0)
        XCTAssertEqual(controller.rightClickMenuPresentationCountForTesting, 0)
    }

    @MainActor
    func testControlClickCustomActionSwallowsTheLeftClickEvent() {
        var dashboardOpens = 0
        let controller = makeController(openDashboard: { dashboardOpens += 1 })
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings(rightClickAction: .openMainWindow)
        )
        let down = makeMouseEvent(.leftMouseDown, modifiers: .control)
        XCTAssertNil(controller.handleStatusItemEventForTesting(down))
        XCTAssertFalse(controller.isStatusMenuBoundForTesting)
        XCTAssertEqual(dashboardOpens, 0)

        let plainLeft = makeMouseEvent(.leftMouseDown)
        XCTAssertTrue(controller.handleStatusItemEventForTesting(plainLeft) === plainLeft)

        let up = makeMouseEvent(.leftMouseUp, modifiers: .control)
        XCTAssertNil(controller.handleStatusItemEventForTesting(up))
    }

    @MainActor
    func testSetAnimationFrameRateClampsAndTakesEffectImmediately() {
        let controller = makeController()
        defer { controller.teardown() }

        XCTAssertEqual(controller.animationFrameRateForTesting, 24)
        controller.setAnimationFrameRate(10)
        XCTAssertEqual(controller.animationFrameRateForTesting, 10)
        controller.setAnimationFrameRate(61)
        XCTAssertEqual(controller.animationFrameRateForTesting, 30)
        controller.setAnimationFrameRate(31)
        XCTAssertEqual(controller.animationFrameRateForTesting, 30)
        controller.setAnimationFrameRate(5)
        XCTAssertEqual(controller.animationFrameRateForTesting, 6)
    }

    @MainActor
    func testClientSwitchLayoutsOnceAndAppliesDeferredRebuildWhileClosed() {
        let controller = makeController()
        defer { controller.teardown() }

        let grokSnapshot = Snapshot.balance(
            "Grok Provider",
            12.34,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let claudeSnapshot = Snapshot.balance(
            "Claude Provider",
            56.78,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_100)
        )
        let grokInput = makeMenuInput(activeClient: .grok, showQuickSwitchMenu: false)
        let claudeInput = makeMenuInput(activeClient: .claude, showQuickSwitchMenu: true)
        let settings = makeSettings()
        let grokIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.15,
            green: 0.15,
            blue: 0.15
        )
        let claudeIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.85,
            green: 0.45,
            blue: 0.15
        )
        grokIcon.isTemplate = true
        claudeIcon.isTemplate = true

        controller.start(
            snapshot: grokSnapshot,
            refreshDate: grokSnapshot.date,
            menuInput: grokInput,
            settings: settings
        )
        controller.setGrokIconForTesting(grokIcon)
        controller.setClaudeAnimationAssetsForTesting(
            staticImage: claudeIcon,
            spriteImage: claudeIcon
        )
        controller.updateActivity(
            activeClient: .grok,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            grokTaskRunning: false,
            animationEnabled: true
        )

        XCTAssertEqual(controller.menuBarPrimaryTextForTesting, grokSnapshot.menuBarPrimary)
        let layoutBefore = controller.layoutStatusItemCallCountForTesting
        let rebuildBefore = controller.statusMenuRebuildCountForTesting
        let menuIdentities = controller.menuItemsForTesting.map { ObjectIdentifier($0) }
        XCTAssertFalse(
            controller.menuItemsForTesting.contains { $0.submenu != nil },
            "the grok dropdown should not include quick switch before the deferred rebuild"
        )

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            grokTaskRunning: false,
            animationEnabled: true,
            layout: false
        )
        XCTAssertEqual(
            controller.layoutStatusItemCallCountForTesting,
            layoutBefore,
            "icon swap before a cached snapshot render must not layout the status item"
        )
        XCTAssertEqual(
            controller.menuBarPrimaryTextForTesting,
            grokSnapshot.menuBarPrimary,
            "digits stay on the previous client until the cached snapshot renders"
        )
        XCTAssertTrue(
            controller.menuBarSourceImageForTesting === claudeIcon,
            "the Claude icon must still swap when layout is skipped"
        )

        controller.update(
            snapshot: claudeSnapshot,
            refreshDate: claudeSnapshot.date,
            menuInput: claudeInput,
            settings: settings,
            deferMenuRebuild: true
        )
        XCTAssertEqual(
            controller.layoutStatusItemCallCountForTesting,
            layoutBefore + 1,
            "one client switch must layout the status item once"
        )
        XCTAssertEqual(controller.menuBarPrimaryTextForTesting, claudeSnapshot.menuBarPrimary)
        XCTAssertNotEqual(controller.menuBarPrimaryTextForTesting, "…")
        XCTAssertNotEqual(controller.menuBarPrimaryTextForTesting, grokSnapshot.menuBarPrimary)
        XCTAssertEqual(
            controller.statusMenuRebuildCountForTesting,
            rebuildBefore,
            "clicking a Terminal tab must not rebuild the dropdown"
        )
        XCTAssertEqual(
            controller.menuItemsForTesting.map { ObjectIdentifier($0) },
            menuIdentities
        )
        XCTAssertTrue(controller.statusMenuNeedsRebuildForTesting)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, rebuildBefore + 1,
            "the deferred rebuild must complete while closed")
        controller.menuWillOpen(controller.statusMenuForTesting)
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, rebuildBefore + 1,
            "opening must not rebuild mounted menu content")
        XCTAssertFalse(controller.statusMenuNeedsRebuildForTesting)
        XCTAssertTrue(
            controller.menuItemsForTesting.contains { $0.submenu != nil },
            "the deferred rebuild must present the new client's menu items"
        )

        controller.menuDidClose(controller.statusMenuForTesting)
    }

    @MainActor
    func testOpenCurrentAgentMenuTitleFollowsActiveClient() {
        let controller = makeController()
        defer { controller.teardown() }
        let settings = makeSettings()

        let expected: [(AssistantClient, LocalizationKey)] = [
            (.codex, .keyStatusItemControllerOpenChatgpt),
            (.grok, .keyStatusItemControllerOpenGrok),
            (.claude, .keyStatusItemControllerOpenClaude)
        ]
        for (client, key) in expected {
            controller.start(
                snapshot: .placeholder,
                refreshDate: nil,
                menuInput: makeMenuInput(activeClient: client, showOpenChatGPTMenu: true),
                settings: settings
            )
            XCTAssertEqual(
                openCurrentAgentMenuItem(in: controller)?.title,
                tr(key),
                "menu title must follow \(client.rawValue)"
            )
            XCTAssertEqual(
                controller.menuItemsForTesting.first { $0.title == tr(.keyStatusItemControllerOpenMainWindow) }?.title,
                tr(.keyStatusItemControllerOpenMainWindow)
            )
        }
    }

    @MainActor
    func testOpenCurrentAgentMenuTitleUpdatesOnNextMenuOpenAfterClientSwitch() {
        let controller = makeController()
        defer { controller.teardown() }
        let settings = makeSettings()
        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(activeClient: .grok, showOpenChatGPTMenu: true),
            settings: settings
        )
        XCTAssertEqual(
            openCurrentAgentMenuItem(in: controller)?.title,
            tr(.keyStatusItemControllerOpenGrok)
        )

        controller.update(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(activeClient: .claude, showOpenChatGPTMenu: true),
            settings: settings,
            deferMenuRebuild: true
        )
        XCTAssertEqual(
            openCurrentAgentMenuItem(in: controller)?.title,
            tr(.keyStatusItemControllerOpenGrok),
            "deferred rebuild must keep the previous title until the menu opens"
        )

        controller.menuWillOpen(controller.statusMenuForTesting)
        XCTAssertEqual(
            openCurrentAgentMenuItem(in: controller)?.title,
            tr(.keyStatusItemControllerOpenClaude)
        )
        controller.menuDidClose(controller.statusMenuForTesting)
    }

    @MainActor
    func testOpenCurrentAgentMenuPreferenceHidesTheItemForEveryClient() {
        let controller = makeController()
        defer { controller.teardown() }
        let settings = makeSettings()
        for client in [AssistantClient.codex, .grok, .claude] {
            controller.start(
                snapshot: .placeholder,
                refreshDate: nil,
                menuInput: makeMenuInput(activeClient: client, showOpenChatGPTMenu: false),
                settings: settings
            )
            XCTAssertNil(openCurrentAgentMenuItem(in: controller))
            XCTAssertFalse(
                controller.menuItemsForTesting.contains {
                    $0.title == tr(.keyStatusItemControllerOpenChatgpt)
                        || $0.title == tr(.keyStatusItemControllerOpenGrok)
                        || $0.title == tr(.keyStatusItemControllerOpenClaude)
                }
            )
        }
    }

    @MainActor
    func testOpenCurrentAgentMenuItemInvokesTheSharedAction() throws {
        var openCount = 0
        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: { openCount += 1 },
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }
        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(activeClient: .grok, showOpenChatGPTMenu: true),
            settings: makeSettings()
        )
        let item = try XCTUnwrap(openCurrentAgentMenuItem(in: controller))
        XCTAssertEqual(item.action, NSSelectorFromString("openChatGPT"))
        XCTAssertTrue(item.target === controller)
        XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: item))
        XCTAssertEqual(openCount, 1)
    }

    @MainActor
    func testStatusItemContentIsAlwaysRenderedFromTheOffscreenBitmapTree() {
        let controller = makeController()
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )

        XCTAssertTrue(controller.menuBarContentIsOffscreenForTesting)
        XCTAssertNotNil(controller.menuBarButtonImageForTesting)
    }

    @MainActor
    func testIconSizePresetScalesSlotWithDrawingSizeAndLeavesNoEmptyMediumSlot() throws {
        let controller = makeController()
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )

        XCTAssertEqual(
            controller.menuBarIconSizeForTesting,
            MenuBarIconSizePreset.medium.pointSize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.grokIdleIconSizeForTesting?.width ?? .nan,
            MenuBarIconSizePreset.medium.pointSize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.grokIdleIconSizeForTesting?.height ?? .nan,
            MenuBarIconSizePreset.medium.pointSize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.menuBarIconSlotWidthForTesting ?? .nan,
            MenuBarIconSizePreset.medium.pointSize,
            accuracy: 0.001
        )
        let mediumLength = try XCTUnwrap(controller.statusItemLengthForTesting)

        controller.updateIconSize(MenuBarIconSizePreset.small.pointSize)
        XCTAssertEqual(
            controller.menuBarIconSlotWidthForTesting ?? .nan,
            MenuBarIconSizePreset.small.pointSize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.grokIdleIconSizeForTesting?.width ?? .nan,
            MenuBarIconSizePreset.small.pointSize,
            accuracy: 0.001
        )
        let smallLength = try XCTUnwrap(controller.statusItemLengthForTesting)
        XCTAssertEqual(
            mediumLength - smallLength,
            MenuBarIconSizePreset.medium.pointSize - MenuBarIconSizePreset.small.pointSize,
            accuracy: 0.5,
            "small must shrink the status item instead of leaving an 18 pt empty slot"
        )

        controller.updateIconSize(MenuBarIconSizePreset.large.pointSize)
        XCTAssertEqual(
            controller.menuBarIconSlotWidthForTesting ?? .nan,
            MenuBarIconSizePreset.large.pointSize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.grokIdleIconSizeForTesting?.width ?? .nan,
            MenuBarIconSizePreset.large.pointSize,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            controller.menuBarIconSlotWidthForTesting ?? .nan,
            22
        )
        let largeLength = try XCTUnwrap(controller.statusItemLengthForTesting)
        XCTAssertEqual(
            largeLength - mediumLength,
            MenuBarIconSizePreset.large.pointSize - MenuBarIconSizePreset.medium.pointSize,
            accuracy: 0.5
        )
    }

    @MainActor
    func testIdleGrokIconLoadsVectorSVGInsteadOfOneXBitmap() throws {
        let idleURL = try XCTUnwrap(
            GrokIdleIcon.bundledSVGURL(),
            "idle Grok must ship as GrokIdle.svg"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: idleURL.path))
        let idleMarkup = try String(contentsOf: idleURL, encoding: .utf8)
        XCTAssertTrue(idleMarkup.contains("m532.29,39.28"))
        let mediumSize = NSSize(
            width: MenuBarIconSizePreset.medium.pointSize,
            height: MenuBarIconSizePreset.medium.pointSize
        )

        GrokIdleIcon.resetCachesForTesting()
        let controller = makeController()
        defer { controller.teardown() }
        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        XCTAssertEqual(
            try XCTUnwrap(controller.grokIdleIconSizeForTesting),
            mediumSize
        )
        XCTAssertLessThanOrEqual(
            controller.grokIdleIconSizeForTesting?.width ?? .nan,
            MenuBarIconSizePreset.medium.pointSize
        )
        XCTAssertTrue(
            controller.grokIdleIsVectorSVGForTesting,
            "idle Frame 16 must stay _NSSVGImageRep"
        )
        let idle = try XCTUnwrap(controller.grokIdleIconImageForTesting)
        XCTAssertTrue(idle.isTemplate)
        XCTAssertTrue(
            idle.representations.compactMap { $0 as? NSBitmapImageRep }.isEmpty,
            "idle Grok must not bake an 18 px 1x bitmap"
        )
    }

    @MainActor
    func testUpdateIconSizeKeepsIdleGrokVectorSVGAcrossPresets() throws {
        XCTAssertNotNil(
            GrokIdleIcon.bundledSVGURL(),
            "idle Grok must ship as GrokIdle.svg"
        )

        GrokIdleIcon.resetCachesForTesting()
        ClaudeThinkingSprite.resetCachesForTesting()
        let controller = makeController()
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        XCTAssertEqual(
            try XCTUnwrap(controller.grokIdleIconSizeForTesting),
            NSSize(
                width: MenuBarIconSizePreset.medium.pointSize,
                height: MenuBarIconSizePreset.medium.pointSize
            )
        )
        XCTAssertTrue(
            controller.grokIdleIsVectorSVGForTesting,
            "idle Frame 16 must stay _NSSVGImageRep"
        )

        for preset in MenuBarIconSizePreset.allCases {
            controller.updateIconSize(preset.pointSize)
            XCTAssertEqual(
                try XCTUnwrap(controller.grokIdleIconSizeForTesting),
                NSSize(width: preset.pointSize, height: preset.pointSize)
            )
            XCTAssertTrue(
                controller.grokIdleIsVectorSVGForTesting,
                "updateIconSize(\(preset.rawValue)) idle must stay vector Frame 16"
            )
        }
        XCTAssertLessThanOrEqual(
            ClaudeThinkingSprite.sourceFrameBuildCountForTesting,
            1,
            "Claude SVG frames must be built once, not on every icon-size click"
        )
    }

    func testCodexAnimationCachePrecomposesFiniteFramesAndReusesSteadyStateLookups() {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        let signature = makeVisualSignature(
            primaryText: "80%",
            sourceFrames: sourceFrames
        )
        var cache = MenuBarBitmapAnimationFrameCache()
        var compositionCount = 0

        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames
            ) { _ in
                compositionCount += 1
                return NSImage(size: NSSize(width: 56, height: 22))
            }
        )
        XCTAssertEqual(cache.count, RotatingTemplateImageView.frameCount)
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount)

        let firstCompleteFrame = cache.image(forSourceFrame: sourceFrames[0])
        for sourceFrame in sourceFrames {
            XCTAssertNotNil(
                cache.image(forSourceFrame: sourceFrame),
                "every prepared source frame must resolve to a complete image"
            )
        }
        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames
            ) { _ in
                XCTFail("a steady-state frame lookup must not compose")
                return nil
            }
        )
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount)
        XCTAssertTrue(cache.image(forSourceFrame: sourceFrames[0]) === firstCompleteFrame)
    }

    func testCodexAnimationCacheInvalidatesForVisualSignatureAndSourceChanges() {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        var cache = MenuBarBitmapAnimationFrameCache()
        var compositionCount = 0
        let initialSignature = makeVisualSignature(
            primaryText: "80%",
            sourceFrames: sourceFrames
        )

        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: initialSignature,
                sourceFrames: sourceFrames
            ) { _ in
                compositionCount += 1
                return NSImage(size: NSSize(width: 56, height: 22))
            }
        )

        let changedTextSignature = makeVisualSignature(
            primaryText: "79%",
            sourceFrames: sourceFrames
        )
        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: changedTextSignature,
                sourceFrames: sourceFrames
            ) { _ in
                compositionCount += 1
                return NSImage(size: NSSize(width: 56, height: 22))
            }
        )
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount * 2)

        let replacementFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        // Keep the visible signature equal while changing source-frame
        // identity. The cache must still reject the old complete images.
        let replacementSignature = makeVisualSignature(
            primaryText: "79%",
            sourceFrames: replacementFrames
        )
        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: replacementSignature,
                sourceFrames: replacementFrames
            ) { _ in
                compositionCount += 1
                return NSImage(size: NSSize(width: 56, height: 22))
            }
        )
        XCTAssertEqual(cache.rebuildCount, 3)
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount * 3)
        XCTAssertNil(cache.image(forSourceFrame: sourceFrames[0]))
        XCTAssertNotNil(cache.image(forSourceFrame: replacementFrames[0]))
    }

    func testCodexAnimationCacheClearsAfterCompositionFailure() {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        let signature = makeVisualSignature(sourceFrames: sourceFrames)
        var cache = MenuBarBitmapAnimationFrameCache()

        XCTAssertFalse(
            cache.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames
            ) { _ in nil }
        )
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.signature)
        XCTAssertEqual(cache.rebuildCount, 0)
    }

    func testStableBitmapFrameBufferMutatesOneImageBackingAcrossManyTicks() throws {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        let completeFrames = (0..<RotatingTemplateImageView.frameCount).map { index in
            makeSolidImage(
                size: NSSize(width: 56, height: 22),
                red: CGFloat(index + 1) / CGFloat(RotatingTemplateImageView.frameCount + 1),
                green: 0.25,
                blue: 0.75
            )
        }
        let signature = makeVisualSignature(sourceFrames: sourceFrames)
        var buffer = MenuBarStableBitmapAnimationFrameBuffer()

        XCTAssertTrue(
            buffer.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames,
                completeFrames: completeFrames
            )
        )
        let stableImage = try XCTUnwrap(buffer.image)
        let initialPixelData = try XCTUnwrap(buffer.backingPixelDataForTesting)
        XCTAssertEqual(buffer.count, RotatingTemplateImageView.frameCount)
        XCTAssertEqual(buffer.rebuildCount, 1)
        XCTAssertEqual(stableImage.cacheMode, .never)

        for tick in 0..<100 {
            XCTAssertTrue(buffer.apply(frameIndex: tick % completeFrames.count))
            XCTAssertTrue(buffer.image === stableImage)
        }

        XCTAssertEqual(buffer.rebuildCount, 1)
        XCTAssertEqual(buffer.pixelCopyCount, 100)
        XCTAssertNotEqual(buffer.backingPixelDataForTesting, initialPixelData)
        XCTAssertTrue(
            buffer.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames,
                completeFrames: completeFrames
            )
        )
        XCTAssertEqual(buffer.rebuildCount, 1)
    }

    func testBitmapVisualSignatureIncludesContentGeometryAppearanceAndRenderingInputs() {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        let base = makeVisualSignature(sourceFrames: sourceFrames)
        let changedText = makeVisualSignature(
            primaryText: "changed",
            sourceFrames: sourceFrames
        )
        let changedGeometry = makeVisualSignature(
            sourceFrames: sourceFrames,
            contentFrame: NSRect(x: 1, y: 0, width: 56, height: 22)
        )
        let changedAppearance = makeVisualSignature(
            sourceFrames: sourceFrames,
            appearance: "darkAqua"
        )
        let changedProvider = makeVisualSignature(
            sourceFrames: sourceFrames,
            sourceProviderIdentity: "another-provider"
        )
        XCTAssertNotEqual(base, changedText)
        XCTAssertNotEqual(base, changedGeometry)
        XCTAssertNotEqual(base, changedAppearance)
        XCTAssertNotEqual(base, changedProvider)
        let replacementFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        var changedSourceFrames = base
        changedSourceFrames.sourceFrameIdentities = replacementFrames.map(ObjectIdentifier.init)
        XCTAssertTrue(
            base.matchesStaticContent(of: changedSourceFrames),
            "animation frame identities must not invalidate static menu-bar content"
        )
    }

    @MainActor
    func testBitmapControllerReusesCompleteCodexFramesAcrossTicksAndRestoresStaticImage() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController()
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = makeMenuInput()
        let settings = makeSettings()

        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        controller.setCodexIconForTesting(
            NSImage(size: NSSize(width: 16, height: 16))
        )
        let staticImage = try XCTUnwrap(controller.menuBarButtonImageForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        let buildCount = controller.codexAnimationCacheBuildCountForTesting
        let compositionCount = controller.codexAnimationFrameCompositionCountForTesting
        let stableImage = try XCTUnwrap(controller.stableCodexAnimationImageForTesting)
        let stableImageAssignments = controller.stableCodexAnimationImageAssignmentCountForTesting
        let stableRebuildCount = controller.stableCodexAnimationRebuildCountForTesting
        XCTAssertEqual(
            controller.codexAnimationCacheFrameCountForTesting,
            RotatingTemplateImageView.frameCount
        )
        XCTAssertEqual(
            controller.stableCodexAnimationFrameCountForTesting,
            RotatingTemplateImageView.frameCount
        )
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount)
        XCTAssertEqual(stableRebuildCount, 1)
        XCTAssertTrue(controller.menuBarButtonImageForTesting === stableImage)
        XCTAssertGreaterThanOrEqual(buildCount, 1)

        controller.update(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        XCTAssertEqual(controller.codexAnimationCacheBuildCountForTesting, buildCount)
        XCTAssertEqual(
            controller.codexAnimationFrameCompositionCountForTesting,
            compositionCount
        )
        XCTAssertEqual(
            controller.stableCodexAnimationImageAssignmentCountForTesting,
            stableImageAssignments
        )
        XCTAssertTrue(controller.menuBarButtonImageForTesting === stableImage)

        for tick in 0..<100 {
            controller.advanceCodexAnimationFrameForTesting(
                tick % RotatingTemplateImageView.frameCount
            )
            XCTAssertTrue(controller.menuBarButtonImageForTesting === stableImage)
        }
        XCTAssertEqual(
            controller.codexAnimationFrameCompositionCountForTesting,
            compositionCount,
            "100 stable-image ticks must not compose complete bitmaps"
        )
        XCTAssertEqual(
            controller.stableCodexAnimationImageAssignmentCountForTesting,
            stableImageAssignments,
            "100 stable-image ticks must not assign button.image"
        )
        XCTAssertEqual(
            controller.stableCodexAnimationPixelCopyCountForTesting,
            101,
            "initial frame plus 100 steady-state ticks should copy pixels"
        )

        let changedSnapshot = Snapshot.balance(
            "Provider",
            79,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        controller.update(
            snapshot: changedSnapshot,
            refreshDate: changedSnapshot.date,
            menuInput: input,
            settings: settings
        )
        let changedBuildCount = controller.codexAnimationCacheBuildCountForTesting
        let changedCompositionCount = controller.codexAnimationFrameCompositionCountForTesting
        let changedStableImage = try XCTUnwrap(controller.stableCodexAnimationImageForTesting)
        XCTAssertEqual(changedBuildCount, buildCount + 1)
        XCTAssertEqual(
            changedCompositionCount,
            compositionCount + RotatingTemplateImageView.frameCount
        )
        XCTAssertTrue(controller.menuBarButtonImageForTesting === changedStableImage)
        XCTAssertFalse(changedStableImage === stableImage)
        XCTAssertEqual(
            controller.stableCodexAnimationImageAssignmentCountForTesting,
            stableImageAssignments + 1
        )

        RunLoop.main.run(
            until: Date().addingTimeInterval(
                RotatingTemplateImageView.rotationFrameInterval * 2
            )
        )
        XCTAssertEqual(
            controller.codexAnimationFrameCompositionCountForTesting,
            changedCompositionCount,
            "steady-state timer ticks must not compose complete bitmaps"
        )

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        let restoredStaticImage = try XCTUnwrap(controller.menuBarButtonImageForTesting)
        XCTAssertFalse(
            restoredStaticImage === staticImage,
            "changed content must restore a newly composed static image"
        )

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertEqual(
            controller.codexAnimationCacheBuildCountForTesting,
            changedBuildCount,
            "restart with unchanged content must reuse the finite frame set"
        )
        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
    }

    @MainActor
    func testRuntimeDisplayPolicyPublishesAndClearsItsWarningImmediately() {
        var visibilityTransitions: [StatusItemVisibility] = []
        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in },
                visibilityChanged: { visibilityTransitions.append($0) }
            )
        )
        defer { controller.teardown() }

        let input = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: nil,
            statusLinks: [],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showStatusMenu: true
        )
        func settings(for mode: MenuBarIconDisplayMode) -> StatusItemController.MenuBarSettings {
            StatusItemController.MenuBarSettings(
                showIcon: true,
                showAmount: true,
                showReset: true,
                horizontalPadding: 6,
                keepMenuOpenAfterRefresh: true,
                iconDisplayMode: mode,
                iconDisplayDelay: .zeroSeconds
            )
        }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: settings(for: .onlyWhileRunning)
        )

        let sampleStart = Date()
        controller.observeCodexTaskSample(false, at: sampleStart)
        controller.observeCodexTaskSample(
            false,
            at: sampleStart.addingTimeInterval(
                MenuBarIconDisplayStateMachine.idleConfirmationInterval
            )
        )

        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(controller.statusItemVisibility.isHiddenByRuntimePolicy)
        XCTAssertFalse(controller.statusItemVisibility.isHiddenByMenuBarSpace)
        XCTAssertEqual(visibilityTransitions.last, .hiddenByRuntimePolicy)

        // Changing the preference is itself a policy transition; it must not
        // wait for another activity sample before restoring the item or
        // clearing the Dashboard-facing warning.
        controller.update(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: settings(for: .alwaysVisible)
        )

        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.statusItemVisibility.isHiddenByRuntimePolicy)
        XCTAssertEqual(visibilityTransitions.last, .unknown)
    }

    @MainActor
    func testNativeCoreAnimationCodexLifecycleUsesOneOwnedHostWithoutBitmapTicks() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(
            codexAnimationBackend: .nativeCoreAnimation
        )
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = makeMenuInput()
        let settings = makeSettings()

        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        let icon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.2,
            green: 0.4,
            blue: 0.8
        )
        icon.isTemplate = true
        controller.setCodexIconForTesting(icon)
        let staticImage = try XCTUnwrap(controller.menuBarButtonImageForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )

        let host = try XCTUnwrap(controller.nativeCodexAnimationHostForTesting)
        XCTAssertEqual(
            controller.codexAnimationBackendForTesting,
            .nativeCoreAnimation
        )
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertTrue(host.superview != nil)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertEqual(host.iconLayer.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(host.iconLayer.bounds.size, host.bounds.size)
        XCTAssertEqual(
            host.iconLayer.position,
            CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        )
        XCTAssertNotNil(host.rotationAnimationForTesting)
        XCTAssertTrue(host.subviews.isEmpty)
        try assertSourceIconCutoutIfHostIsSibling(controller, host: host)
        XCTAssertTrue(
            controller.menuBarButtonImageForTesting === staticImage,
            "running CA presentation must keep the canonical static GPT+text bitmap"
        )
        XCTAssertTrue(
            controller.menuBarButtonImageForTesting
                === controller.cachedStaticMenuBarContentBitmapForTesting
        )
        XCTAssertTrue(
            controller.menuBarButtonImageForTesting
                !== controller.cachedMenuBarTextBitmapForTesting,
            "Performance/G must not replace the native image with the text-only bitmap"
        )

        let installCount = host.rotationAnimationInstallCount
        let rasterizationCount = host.contentsRasterizationCount
        controller.update(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        XCTAssertEqual(host.rotationAnimationInstallCount, installCount)
        XCTAssertEqual(host.contentsRasterizationCount, rasterizationCount)

        // This seam represents a legacy timer callback.  Native CA must leave
        // it unable to copy pixels or request a native redraw.
        let pixelCopies = controller.stableCodexAnimationPixelCopyCountForTesting
        let redraws = controller.stableCodexAnimationRedrawRequestCountForTesting
        controller.advanceCodexAnimationFrameForTesting(7)
        XCTAssertEqual(controller.stableCodexAnimationPixelCopyCountForTesting, pixelCopies)
        XCTAssertEqual(controller.stableCodexAnimationRedrawRequestCountForTesting, redraws)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertNil(host.superview)
        XCTAssertTrue(host.isHidden)
        XCTAssertNil(host.rotationAnimationForTesting)
        XCTAssertNil(controller.nativeCodexSourceIconMaskForTesting)
        XCTAssertTrue(controller.menuBarButtonImageForTesting === staticImage)
    }

    @MainActor
    func testNativeCoreAnimationKeepsCanonicalStaticImageAcrossHostLifecycle() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(
            codexAnimationBackend: .nativeCoreAnimation
        )
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = makeMenuInput()
        let settings = makeSettings()

        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        let icon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.2,
            green: 0.4,
            blue: 0.8
        )
        icon.isTemplate = true
        controller.setCodexIconForTesting(icon)

        func assertCanonicalStaticNativeImage(
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let buttonImage = try XCTUnwrap(
                controller.menuBarButtonImageForTesting,
                file: file,
                line: line
            )
            let staticImage = try XCTUnwrap(
                controller.cachedStaticMenuBarContentBitmapForTesting,
                file: file,
                line: line
            )
            let textBitmap = try XCTUnwrap(
                controller.cachedMenuBarTextBitmapForTesting,
                file: file,
                line: line
            )
            XCTAssertTrue(
                buttonImage === staticImage,
                message,
                file: file,
                line: line
            )
            XCTAssertTrue(
                buttonImage !== textBitmap,
                "native image must not be the text-only bitmap: \(message)",
                file: file,
                line: line
            )
        }

        try assertCanonicalStaticNativeImage("idle native image is the complete static bitmap")
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        try assertCanonicalStaticNativeImage(
            "running Performance/G must keep the complete static GPT+text bitmap"
        )
        let host = try XCTUnwrap(controller.nativeCodexAnimationHostForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertTrue(host.superview != nil)
        XCTAssertFalse(host.isHidden)
        XCTAssertNotNil(host.rotationAnimationForTesting)
        XCTAssertTrue(host.subviews.isEmpty)
        try assertSourceIconCutoutIfHostIsSibling(controller, host: host)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)

        let installCount = host.rotationAnimationInstallCount
        let rasterizationCount = host.contentsRasterizationCount
        let runningStaticImage = controller.cachedStaticMenuBarContentBitmapForTesting
        controller.update(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        try assertCanonicalStaticNativeImage(
            "snapshot updates must not replace the canonical static native image"
        )
        XCTAssertTrue(controller.menuBarButtonImageForTesting === runningStaticImage)
        XCTAssertEqual(host.rotationAnimationInstallCount, installCount)
        XCTAssertEqual(host.contentsRasterizationCount, rasterizationCount)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        try assertCanonicalStaticNativeImage("stopped Performance/G restores the static native image")
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertNil(host.superview)
        XCTAssertTrue(host.isHidden)
        XCTAssertNil(host.rotationAnimationForTesting)
        XCTAssertNil(controller.nativeCodexSourceIconMaskForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        try assertCanonicalStaticNativeImage(
            "restarting Performance/G must still keep the complete static native image"
        )
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationHostForTesting?.superview != nil)
        XCTAssertNotNil(
            controller.nativeCodexAnimationHostForTesting?.rotationAnimationForTesting
        )

        controller.setCodexAnimationBackend(.stableBitmap)
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertNil(controller.nativeCodexAnimationHostForTesting?.superview)
        XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)

        controller.setCodexAnimationBackend(.nativeCoreAnimation)
        try assertCanonicalStaticNativeImage(
            "returning to Performance/G must restore the complete static native image"
        )
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationHostForTesting?.superview != nil)
        XCTAssertNotNil(
            controller.nativeCodexAnimationHostForTesting?.rotationAnimationForTesting
        )
    }

    @MainActor
    func testClaudeThinkingLifecycleUsesOneOwnedSpriteHostWithoutBitmapTicks() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Claude animation is disabled by the system reduce-motion setting"
        )
        var animationTransitions: [(Bool, NSImage?, NSImage?)] = []
        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in },
                claudeAnimationStateChanged: { active, iconImage, spriteImage in
                    animationTransitions.append((active, iconImage, spriteImage))
                }
            )
        )
        defer { controller.teardown() }

        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        let staticIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        staticIcon.isTemplate = true
        let sprite = makeSolidImage(
            size: NSSize(width: 16, height: 144),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        sprite.isTemplate = true
        controller.setClaudeAnimationAssetsForTesting(
            staticImage: staticIcon,
            spriteImage: sprite
        )
        let staticBitmap = try XCTUnwrap(controller.menuBarButtonImageForTesting)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: true,
            animationEnabled: true
        )

        let host = try XCTUnwrap(controller.claudeThinkingAnimationHostForTesting)
        XCTAssertTrue(controller.claudeThinkingAnimationIsActiveForTesting)
        XCTAssertEqual(host.timing.frameCount, 9)
        XCTAssertEqual(MenuBarClaudeAnimatedIconHostView.thinkingFrameCount, 9)
        XCTAssertTrue(host.superview != nil)
        XCTAssertFalse(host.isHidden)
        XCTAssertNotNil(host.thinkingAnimationForTesting)
        XCTAssertTrue(controller.menuBarButtonImageForTesting !== staticBitmap)
        XCTAssertEqual(animationTransitions.count, 1)
        XCTAssertTrue(animationTransitions[0].0)
        XCTAssertTrue(animationTransitions[0].1 === staticIcon)
        XCTAssertTrue(animationTransitions[0].2 === sprite)

        let installCount = host.thinkingAnimationInstallCount
        let rasterizationCount = host.spriteRasterizationCount
        controller.update(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        XCTAssertEqual(host.thinkingAnimationInstallCount, installCount)
        XCTAssertEqual(host.spriteRasterizationCount, rasterizationCount)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)
        XCTAssertTrue(host.isHidden)
        XCTAssertNil(host.thinkingAnimationForTesting)
        XCTAssertEqual(animationTransitions.count, 2)
        XCTAssertFalse(animationTransitions[1].0)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(host.isHidden)
        XCTAssertNil(host.superview)
    }

    @MainActor
    func testCodexIdleReclaimsSourceAfterClaudeIdleAndRunningRoundTrips() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Claude animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(codexAnimationBackend: .stableBitmap)
        defer { controller.teardown() }

        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )

        let codexIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.2,
            green: 0.4,
            blue: 0.8
        )
        codexIcon.isTemplate = true
        let claudeIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        claudeIcon.isTemplate = true
        let claudeSprite = makeSolidImage(
            size: NSSize(width: 16, height: 144),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        claudeSprite.isTemplate = true
        controller.setCodexIconForTesting(codexIcon)
        controller.setClaudeAnimationAssetsForTesting(
            staticImage: claudeIcon,
            spriteImage: claudeSprite
        )

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === codexIcon)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === claudeIcon)
        XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(
            controller.menuBarSourceImageForTesting === codexIcon,
            "idle Codex must reclaim source ownership after idle Claude"
        )
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: true,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === claudeIcon)
        XCTAssertTrue(controller.claudeThinkingAnimationIsActiveForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: true,
            animationEnabled: true
        )
        XCTAssertTrue(
            controller.menuBarSourceImageForTesting === codexIcon,
            "idle Codex must reclaim source ownership after animated Claude"
        )
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)
        XCTAssertNil(controller.claudeThinkingAnimationHostForTesting?.superview)
    }

    @MainActor
    func testGrokIdleAndRunningKeepGrokSourceThroughClaudeAndCodexRoundTrips() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Grok sprite animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(codexAnimationBackend: .stableBitmap)
        defer { controller.teardown() }

        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )

        let codexIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.2,
            green: 0.4,
            blue: 0.8
        )
        codexIcon.isTemplate = true
        let grokIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.1,
            green: 0.1,
            blue: 0.1
        )
        grokIcon.isTemplate = true
        let claudeIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        claudeIcon.isTemplate = true
        let claudeSprite = makeSolidImage(
            size: NSSize(width: 16, height: 144),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        claudeSprite.isTemplate = true
        let grokSprite = makeSolidImage(
            size: NSSize(
                width: 16,
                height: 16 * CGFloat(GrokThinkingAnimationTiming.frameCount)
            ),
            red: 0.95,
            green: 0.95,
            blue: 0.95
        )
        grokSprite.isTemplate = true
        controller.setCodexIconForTesting(codexIcon)
        controller.setGrokIconsForTesting(idle: grokIcon, thinking: grokSprite)
        controller.setClaudeAnimationAssetsForTesting(
            staticImage: claudeIcon,
            spriteImage: claudeSprite
        )

        controller.updateActivity(
            activeClient: .grok,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            grokTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === grokIcon)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            grokTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === claudeIcon)

        controller.updateActivity(
            activeClient: .grok,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            grokTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(
            controller.menuBarSourceImageForTesting === grokIcon,
            "idle Grok must reclaim source ownership after idle Claude"
        )

        controller.updateActivity(
            activeClient: .grok,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            grokTaskRunning: true,
            animationEnabled: true
        )
        XCTAssertTrue(
            controller.menuBarSourceImageForTesting === grokIcon,
            "running Grok must keep the spark as the semantic source"
        )
        XCTAssertTrue(controller.grokThinkingAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)
        XCTAssertNil(controller.claudeThinkingAnimationHostForTesting?.superview)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: true,
            grokTaskRunning: true,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === claudeIcon)
        XCTAssertTrue(controller.claudeThinkingAnimationIsActiveForTesting)
        XCTAssertEqual(
            controller.claudeThinkingAnimationHostForTesting?.timing.frameCount,
            9
        )
        XCTAssertFalse(controller.grokThinkingAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)

        controller.updateActivity(
            activeClient: .grok,
            codexTaskRunning: false,
            claudeTaskRunning: true,
            grokTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(
            controller.menuBarSourceImageForTesting === grokIcon,
            "idle Grok must reclaim source ownership after Claude thinking"
        )
        XCTAssertFalse(controller.grokThinkingAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)
        XCTAssertNil(controller.claudeThinkingAnimationHostForTesting?.superview)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            grokTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === codexIcon)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
    }

    @MainActor
    func testGrokIdleUsesSparkAndRunningUsesThinkingSprite() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Grok sprite animation is disabled by the system reduce-motion setting"
        )

        for backend in [MenuBarCodexAnimationBackend.stableBitmap, .nativeCoreAnimation] {
            let controller = makeController(codexAnimationBackend: backend)
            defer { controller.teardown() }

            let snapshot = Snapshot.balance(
                "Provider",
                80,
                "USD",
                nil,
                Date(timeIntervalSince1970: 1_700_000_000)
            )
            controller.start(
                snapshot: snapshot,
                refreshDate: snapshot.date,
                menuInput: makeMenuInput(),
                settings: makeSettings()
            )

            let spark = makeSolidImage(
                size: NSSize(width: 16, height: 16),
                red: 0.1,
                green: 0.1,
                blue: 0.1
            )
            spark.isTemplate = true
            let sprite = makeSolidImage(
                size: NSSize(
                    width: 16,
                    height: 16 * CGFloat(GrokThinkingAnimationTiming.frameCount)
                ),
                red: 0.95,
                green: 0.95,
                blue: 0.95
            )
            sprite.isTemplate = true
            controller.setGrokIconsForTesting(idle: spark, thinking: sprite)

            controller.updateActivity(
                activeClient: .grok,
                codexTaskRunning: false,
                claudeTaskRunning: false,
                grokTaskRunning: false,
                animationEnabled: true
            )
            XCTAssertTrue(
                controller.menuBarSourceImageForTesting === spark,
                "idle Grok must use the spark, backend=\(backend)"
            )
            XCTAssertFalse(
                controller.grokThinkingAnimationIsActiveForTesting,
                "idle Grok must not play the thinking sprite, backend=\(backend)"
            )
            XCTAssertFalse(
                controller.nativeCodexAnimationIsRotatingForTesting,
                "idle Grok must not spin the bitmap rotator, backend=\(backend)"
            )
            XCTAssertFalse(
                controller.nativeCodexAnimationIsActiveForTesting,
                "idle Grok must not install native rotation, backend=\(backend)"
            )

            controller.updateActivity(
                activeClient: .grok,
                codexTaskRunning: false,
                claudeTaskRunning: false,
                grokTaskRunning: true,
                animationEnabled: true
            )
            XCTAssertTrue(
                controller.menuBarSourceImageForTesting === spark,
                "running Grok must keep the spark source, backend=\(backend)"
            )
            XCTAssertTrue(
                controller.grokThinkingAnimationIsActiveForTesting,
                "running Grok must play the thinking sprite, backend=\(backend)"
            )
            XCTAssertFalse(
                controller.nativeCodexAnimationIsRotatingForTesting,
                "running Grok must not rotate the spark, backend=\(backend)"
            )
            XCTAssertFalse(
                controller.nativeCodexAnimationIsActiveForTesting,
                "running Grok must not install Codex rotation, backend=\(backend)"
            )
            let buttonImage = try XCTUnwrap(controller.menuBarButtonImageForTesting)
            XCTAssertTrue(
                buttonImage !== controller.cachedMenuBarTextBitmapForTesting,
                "Grok must not use a text-only replicant bitmap, backend=\(backend)"
            )
            switch backend {
            case .stableBitmap:
                XCTAssertNotNil(controller.grokThinkingStableImageForTesting)
                XCTAssertEqual(
                    controller.grokThinkingStableFrameCountForTesting,
                    GrokThinkingAnimationTiming.frameCount
                )
                XCTAssertNil(controller.grokThinkingAnimationHostForTesting?.superview)
            case .nativeCoreAnimation:
                XCTAssertTrue(
                    buttonImage === controller.cachedStaticMenuBarContentBitmapForTesting,
                    "Performance/G must keep the complete static Grok+text bitmap"
                )
                XCTAssertNotNil(controller.grokThinkingAnimationHostForTesting?.superview)
                XCTAssertEqual(
                    controller.grokThinkingAnimationHostForTesting?.timing.frameCount,
                    GrokThinkingAnimationTiming.frameCount
                )
                XCTAssertEqual(
                    controller.grokThinkingAnimationHostForTesting?.timing.restingFrameIndex,
                    GrokThinkingAnimationTiming.restingFrameIndex
                )
            }

            controller.updateActivity(
                activeClient: .grok,
                codexTaskRunning: false,
                claudeTaskRunning: false,
                grokTaskRunning: true,
                animationEnabled: false
            )
            XCTAssertTrue(
                controller.menuBarSourceImageForTesting === spark,
                "animation toggle must keep the static Grok icon, backend=\(backend)"
            )
            XCTAssertFalse(
                controller.grokThinkingAnimationIsActiveForTesting,
                "animation toggle must stop the thinking sprite, backend=\(backend)"
            )

            controller.updateActivity(
                activeClient: .grok,
                codexTaskRunning: false,
                claudeTaskRunning: false,
                grokTaskRunning: false,
                animationEnabled: true
            )
            XCTAssertTrue(
                controller.menuBarSourceImageForTesting === spark,
                "completed Grok must restore the spark, backend=\(backend)"
            )
            XCTAssertFalse(
                controller.grokThinkingAnimationIsActiveForTesting,
                "completed Grok must stop the sprite, backend=\(backend)"
            )
        }
    }

    @MainActor
    func testGrokAnimationModeSwitchFollowsMenuBarBackend() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Grok sprite animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(codexAnimationBackend: .nativeCoreAnimation)
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        let spark = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.1,
            green: 0.1,
            blue: 0.1
        )
        spark.isTemplate = true
        let sprite = makeSolidImage(
            size: NSSize(
                width: 16,
                height: 16 * CGFloat(GrokThinkingAnimationTiming.frameCount)
            ),
            red: 0.95,
            green: 0.95,
            blue: 0.95
        )
        sprite.isTemplate = true
        controller.setGrokIconsForTesting(idle: spark, thinking: sprite)
        controller.updateActivity(
            activeClient: .grok,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            grokTaskRunning: true,
            animationEnabled: true
        )
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertTrue(controller.grokThinkingAnimationIsActiveForTesting)
        XCTAssertNotNil(controller.grokThinkingAnimationHostForTesting?.superview)
        XCTAssertEqual(
            controller.grokThinkingAnimationHostForTesting?.timing.restingFrameIndex,
            15
        )
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        let buttonImage = try XCTUnwrap(controller.menuBarButtonImageForTesting)
        XCTAssertTrue(buttonImage === controller.cachedStaticMenuBarContentBitmapForTesting)
        XCTAssertTrue(buttonImage !== controller.cachedMenuBarTextBitmapForTesting)

        controller.setCodexAnimationBackend(.stableBitmap)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .stableBitmap)
        XCTAssertTrue(controller.grokThinkingAnimationIsActiveForTesting)
        XCTAssertNil(controller.grokThinkingAnimationHostForTesting?.superview)
        XCTAssertNotNil(controller.grokThinkingStableImageForTesting)
        XCTAssertEqual(
            controller.grokThinkingStableFrameCountForTesting,
            GrokThinkingAnimationTiming.frameCount
        )
        XCTAssertTrue(
            controller.menuBarButtonImageForTesting
                !== controller.cachedMenuBarTextBitmapForTesting
        )
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)

        controller.setCodexAnimationBackend(.nativeCoreAnimation)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertTrue(controller.grokThinkingAnimationIsActiveForTesting)
        XCTAssertNotNil(controller.grokThinkingAnimationHostForTesting?.superview)
        XCTAssertTrue(
            controller.menuBarButtonImageForTesting
                === controller.cachedStaticMenuBarContentBitmapForTesting
        )
        XCTAssertTrue(
            controller.menuBarButtonImageForTesting
                !== controller.cachedMenuBarTextBitmapForTesting
        )
    }

    @MainActor
    func testCodexRunningThroughClaudeToCodexIdleRestoresSourceForBothBackends() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )

        for backend in [MenuBarCodexAnimationBackend.stableBitmap, .nativeCoreAnimation] {
            let controller = makeController(codexAnimationBackend: backend)

            let snapshot = Snapshot.balance(
                "Provider",
                80,
                "USD",
                nil,
                Date(timeIntervalSince1970: 1_700_000_000)
            )
            controller.start(
                snapshot: snapshot,
                refreshDate: snapshot.date,
                menuInput: makeMenuInput(),
                settings: makeSettings()
            )

            let codexIcon = makeSolidImage(
                size: NSSize(width: 16, height: 16),
                red: 0.2,
                green: 0.4,
                blue: 0.8
            )
            codexIcon.isTemplate = true
            let claudeIcon = makeSolidImage(
                size: NSSize(width: 16, height: 16),
                red: 0.9,
                green: 0.5,
                blue: 0.2
            )
            claudeIcon.isTemplate = true
            let claudeSprite = makeSolidImage(
                size: NSSize(width: 16, height: 144),
                red: 0.9,
                green: 0.5,
                blue: 0.2
            )
            claudeSprite.isTemplate = true
            controller.setCodexIconForTesting(codexIcon)
            controller.setClaudeAnimationAssetsForTesting(
                staticImage: claudeIcon,
                spriteImage: claudeSprite
            )

            controller.updateActivity(
                activeClient: .codex,
                codexTaskRunning: true,
                claudeTaskRunning: false,
                animationEnabled: true
            )
            XCTAssertTrue(controller.menuBarSourceImageForTesting === codexIcon)
            switch backend {
            case .stableBitmap:
                XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)
            case .nativeCoreAnimation:
                XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
                XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
            }

            controller.updateActivity(
                activeClient: .claude,
                codexTaskRunning: true,
                claudeTaskRunning: false,
                animationEnabled: true
            )
            XCTAssertTrue(
                controller.menuBarSourceImageForTesting === claudeIcon,
                "Codex to Claude must immediately install Claude source"
            )
            XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
            XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)

            controller.updateActivity(
                activeClient: .codex,
                codexTaskRunning: false,
                claudeTaskRunning: false,
                animationEnabled: true
            )
            XCTAssertTrue(
                controller.menuBarSourceImageForTesting === codexIcon,
                "idle Codex must reclaim source ownership after running Codex"
            )
            XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
            XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
            XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)

            controller.teardown()
        }
    }

    @MainActor
    func testCachedClientRoundTripReactivatesRunningCodexExactlyOnceForBothBackends() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )

        for backend in [MenuBarCodexAnimationBackend.stableBitmap, .nativeCoreAnimation] {
            let controller = makeController(codexAnimationBackend: backend)
            let snapshot = Snapshot.balance(
                "Provider",
                80,
                "USD",
                nil,
                Date(timeIntervalSince1970: 1_700_000_000)
            )
            let settings = makeSettings()
            controller.start(
                snapshot: snapshot,
                refreshDate: snapshot.date,
                menuInput: makeMenuInput(activeClient: .codex),
                settings: settings
            )

            let codexIcon = makeSolidImage(
                size: NSSize(width: 16, height: 16),
                red: 0.2,
                green: 0.4,
                blue: 0.8
            )
            codexIcon.isTemplate = true
            let claudeIcon = makeSolidImage(
                size: NSSize(width: 16, height: 16),
                red: 0.9,
                green: 0.5,
                blue: 0.2
            )
            claudeIcon.isTemplate = true
            let claudeSprite = makeSolidImage(
                size: NSSize(width: 16, height: 144),
                red: 0.9,
                green: 0.5,
                blue: 0.2
            )
            claudeSprite.isTemplate = true
            controller.setCodexIconForTesting(codexIcon)
            controller.setClaudeAnimationAssetsForTesting(
                staticImage: claudeIcon,
                spriteImage: claudeSprite
            )

            controller.updateActivity(
                activeClient: .codex,
                codexTaskRunning: true,
                claudeTaskRunning: false,
                animationEnabled: true
            )
            let firstStableTimer = controller.stableCodexAnimationTimerForTesting
            let nativeHost = controller.nativeCodexAnimationHostForTesting
            XCTAssertEqual(
                controller.nativeCodexAnimationInstallCountForTesting,
                backend == .nativeCoreAnimation ? 1 : 0
            )

            controller.updateActivity(
                activeClient: .claude,
                codexTaskRunning: true,
                claudeTaskRunning: false,
                animationEnabled: true,
                layout: false
            )
            XCTAssertTrue(controller.menuBarSourceImageForTesting === claudeIcon)
            XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
            XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
            XCTAssertFalse(firstStableTimer?.isValid ?? false)
            controller.update(
                snapshot: snapshot,
                refreshDate: snapshot.date,
                menuInput: makeMenuInput(activeClient: .claude),
                settings: settings
            )

            controller.updateActivity(
                activeClient: .codex,
                codexTaskRunning: true,
                claudeTaskRunning: false,
                animationEnabled: true,
                layout: false
            )
            XCTAssertTrue(controller.menuBarSourceImageForTesting === codexIcon)
            XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
            XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
            controller.update(
                snapshot: snapshot,
                refreshDate: snapshot.date,
                menuInput: makeMenuInput(activeClient: .codex),
                settings: settings
            )

            switch backend {
            case .stableBitmap:
                let resumedTimer = try XCTUnwrap(controller.stableCodexAnimationTimerForTesting)
                XCTAssertTrue(resumedTimer.isValid)
                XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)
                XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
                controller.update(
                    snapshot: snapshot,
                    refreshDate: snapshot.date,
                    menuInput: makeMenuInput(activeClient: .codex),
                    settings: settings
                )
                XCTAssertTrue(controller.stableCodexAnimationTimerForTesting === resumedTimer)
            case .nativeCoreAnimation:
                XCTAssertTrue(controller.nativeCodexAnimationHostForTesting === nativeHost)
                XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
                XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
                XCTAssertEqual(controller.nativeCodexAnimationInstallCountForTesting, 2)
                controller.update(
                    snapshot: snapshot,
                    refreshDate: snapshot.date,
                    menuInput: makeMenuInput(activeClient: .codex),
                    settings: settings
                )
                XCTAssertEqual(controller.nativeCodexAnimationInstallCountForTesting, 2)
            }

            controller.updateActivity(
                activeClient: .codex,
                codexTaskRunning: false,
                claudeTaskRunning: false,
                animationEnabled: true
            )
            XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
            XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)

            controller.updateActivity(
                activeClient: .claude,
                codexTaskRunning: false,
                claudeTaskRunning: false,
                animationEnabled: true,
                layout: false
            )
            controller.update(
                snapshot: snapshot,
                refreshDate: snapshot.date,
                menuInput: makeMenuInput(activeClient: .claude),
                settings: settings
            )
            controller.updateActivity(
                activeClient: .codex,
                codexTaskRunning: false,
                claudeTaskRunning: false,
                animationEnabled: true,
                layout: false
            )
            controller.update(
                snapshot: snapshot,
                refreshDate: snapshot.date,
                menuInput: makeMenuInput(activeClient: .codex),
                settings: settings
            )
            XCTAssertTrue(controller.menuBarSourceImageForTesting === codexIcon)
            XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
            XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)

            controller.updateActivity(
                activeClient: .codex,
                codexTaskRunning: true,
                claudeTaskRunning: false,
                animationEnabled: true
            )
            switch backend {
            case .stableBitmap:
                let restartedTimer = try XCTUnwrap(controller.stableCodexAnimationTimerForTesting)
                XCTAssertTrue(restartedTimer.isValid)
                XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)
            case .nativeCoreAnimation:
                XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
                XCTAssertEqual(controller.nativeCodexAnimationInstallCountForTesting, 3)
            }

            controller.teardown()
        }
    }

    @MainActor
    func testCodexAnimationModeSwitchIsImmediateAndKeepsExactlyOneBackendActive() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(codexAnimationBackend: .nativeCoreAnimation)
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let settings = makeSettings()
        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: settings
        )
        let icon = makeSolidImage(size: NSSize(width: 16, height: 16), red: 0.2, green: 0.4, blue: 0.8)
        icon.isTemplate = true
        controller.setCodexIconForTesting(icon)
        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        let host = try XCTUnwrap(controller.nativeCodexAnimationHostForTesting)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)

        controller.setCodexAnimationBackend(.stableBitmap)
        XCTAssertEqual(controller.preferredCodexAnimationBackendForTesting, .stableBitmap)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .stableBitmap)
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertNil(host.superview)
        XCTAssertNil(host.rotationAnimationForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertEqual(controller.stableCodexAnimationFrameCountForTesting, 36)

        controller.setCodexAnimationBackend(.nativeCoreAnimation)
        XCTAssertEqual(controller.preferredCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertTrue(
            controller.nativeCodexAnimationHostForTesting?.rotationAnimationForTesting != nil
        )
        XCTAssertFalse(controller.codexAnimationFallbackActiveForTesting)
    }

    @MainActor
    func testEfficientModeFailureFallsBackTemporarilyWithoutChangingPreference() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        var fallbackTransitions: [Bool] = []
        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in },
                animationFallbackChanged: { fallbackTransitions.append($0) }
            ),
            codexAnimationBackend: .nativeCoreAnimation,
            forceNativeCodexAnimationFailureForTesting: true
        )
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        let icon = makeSolidImage(size: NSSize(width: 16, height: 16), red: 0.2, green: 0.4, blue: 0.8)
        icon.isTemplate = true
        controller.setCodexIconForTesting(icon)
        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )

        XCTAssertEqual(controller.preferredCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .stableBitmap)
        XCTAssertTrue(controller.codexAnimationFallbackActiveForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertEqual(fallbackTransitions, [true])

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertFalse(controller.codexAnimationFallbackActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertEqual(fallbackTransitions, [true, false])
    }

    private func assertSourceIconCutoutIfHostIsSibling(
        _ controller: StatusItemController,
        host: MenuBarNativeAnimatedIconHostView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNotNil(host.superview, "running native host must be attached", file: file, line: line)
        if host.superview is NSStatusBarButton {
            XCTAssertNil(
                controller.nativeCodexSourceIconMaskForTesting,
                "a button-child host cannot use the source icon cutout",
                file: file,
                line: line
            )
            return
        }
        let mask = try XCTUnwrap(
            controller.nativeCodexSourceIconMaskForTesting,
            "a sibling host must clip the source static GPT",
            file: file,
            line: line
        )
        XCTAssertEqual(mask.fillRule, .evenOdd, file: file, line: line)
        XCTAssertNotNil(mask.path, file: file, line: line)
    }

    private func makeSolidImage(
        size: NSSize,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            NSColor(
                calibratedRed: red,
                green: green,
                blue: blue,
                alpha: 1
            ).setFill()
            rect.fill()
            return true
        }
    }

    private func makeController(
        codexAnimationBackend: MenuBarCodexAnimationBackend = .stableBitmap,
        forceNativeCodexAnimationFailureForTesting: Bool = false,
        openDashboard: @escaping () -> Void = {},
        openChatGPT: @escaping () -> Void = {},
        openCCSwitch: @escaping () -> Void = {}
    ) -> StatusItemController {
        StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: openDashboard,
                openChatGPT: openChatGPT,
                openCCSwitch: openCCSwitch,
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            ),
            codexAnimationBackend: codexAnimationBackend,
            forceNativeCodexAnimationFailureForTesting: forceNativeCodexAnimationFailureForTesting
        )
    }

    private func makeMenuInput(
        activeClient: AssistantClient = .codex,
        showQuickSwitchMenu: Bool = false,
        showOpenChatGPTMenu: Bool = false
    ) -> StatusItemController.MenuInput {
        StatusItemController.MenuInput(
            choices: showQuickSwitchMenu
                ? [ProviderChoice(id: "provider", name: "Provider", isCurrent: true)]
                : [],
            quickSwitchSummaries: showQuickSwitchMenu ? ["provider": "$1.00"] : [:],
            activeClient: activeClient,
            openAIAccount: nil,
            statusLinks: [],
            showQuickSwitchMenu: showQuickSwitchMenu,
            showOpenChatGPTMenu: showOpenChatGPTMenu,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false
        )
    }

    private func openCurrentAgentMenuItem(
        in controller: StatusItemController
    ) -> NSMenuItem? {
        let titles: Set<String> = [
            tr(.keyStatusItemControllerOpenChatgpt),
            tr(.keyStatusItemControllerOpenGrok),
            tr(.keyStatusItemControllerOpenClaude)
        ]
        return controller.menuItemsForTesting.first { titles.contains($0.title) }
    }

    private func makeSettings(
        rightClickAction: MenuBarRightClickAction = .defaultValue,
        reverseMouseButtons: Bool = false
    ) -> StatusItemController.MenuBarSettings {
        StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true,
            rightClickAction: rightClickAction,
            reverseMouseButtons: reverseMouseButtons
        )
    }

    private func makeMouseEvent(
        _ type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 1, y: 1),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func makeVisualSignature(
        primaryText: String = "…",
        sourceFrames: [NSImage],
        contentFrame: NSRect = NSRect(x: 0, y: 0, width: 56, height: 22),
        appearance: String = "aqua",
        sourceProviderIdentity: String = "provider"
    ) -> MenuBarBitmapAnimationVisualSignature {
        MenuBarBitmapAnimationVisualSignature(
            primaryText: primaryText,
            secondaryText: "reset",
            primaryFont: "Monospaced|13.0|1",
            secondaryFont: "Monospaced|10.4|1",
            contentFrame: contentFrame,
            iconSlotFrame: NSRect(x: 0, y: 3, width: 18, height: 18),
            iconFrame: NSRect(x: 0, y: 3, width: 18, height: 18),
            textFrame: NSRect(x: 24, y: 1, width: 32, height: 20),
            contentBounds: contentFrame,
            iconSlotBounds: NSRect(x: 0, y: 0, width: 18, height: 18),
            iconBounds: NSRect(x: 0, y: 0, width: 18, height: 18),
            textBounds: NSRect(x: 0, y: 0, width: 32, height: 20),
            bitmapBounds: NSRect(x: 0, y: 0, width: 56, height: 22),
            bitmapFrame: NSRect(x: 0, y: 0, width: 56, height: 22),
            buttonBounds: NSRect(x: 0, y: 0, width: 56, height: 22),
            placement: MenuBarBitmapImagePlacement(
                canonicalBounds: NSRect(x: 0, y: 0, width: 56, height: 22),
                imageDestinationRect: NSRect(x: 0, y: 0, width: 56, height: 22)
            ),
            backingScale: 2,
            iconVisible: true,
            textVisible: true,
            primaryVisible: true,
            secondaryVisible: true,
            sourceImageIdentity: sourceFrames.first.map(ObjectIdentifier.init),
            sourceImageSize: NSSize(width: 16, height: 16),
            sourceImageIsTemplate: true,
            sourceFrameIdentities: sourceFrames.map(ObjectIdentifier.init),
            sourceProviderIdentity: sourceProviderIdentity,
            activeClient: .codex,
            effectiveSnapshot: MenuBarBitmapAnimationSnapshotSignature(
                kind: "official",
                provider: sourceProviderIdentity,
                amount: 80,
                unit: "%",
                message: "reset",
                primaryText: primaryText,
                secondaryText: "reset"
            ),
            appearance: appearance,
            iconOffsetX: 0,
            iconOffsetY: 0,
            amountOffsetX: 0,
            amountOffsetY: 0,
            horizontalPadding: 6,
            widthAdjustment: 0,
            showReset: true,
            buttonImagePosition: 1,
            buttonImageScaling: 2
        )
    }
}


extension StatusItemControllerTests {
    @MainActor
    func testMenuRefreshTimestampReformatsExistingSnapshotAfterZoneChange() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T23:30:00Z"))
        let snapshot = Snapshot.balance("Test", 10, "USD", nil, date)
        let controller = makeController()
        defer { controller.teardown() }
        let settings: (Int) -> StatusItemController.MenuBarSettings = { minutes in
            .init(showIcon: true, showAmount: true, showReset: true, horizontalPadding: 6, keepMenuOpenAfterRefresh: true, displayTimeZone: AppTimeZoneSelection.fixedOffset(minutes: minutes).resolved())
        }
        controller.start(snapshot: snapshot, refreshDate: date, menuInput: makeMenuInput(), settings: settings(0))
        func texts(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts)
        }
        let before = controller.menuItemsForTesting.compactMap(\.view).flatMap(texts)
        XCTAssertTrue(before.contains("23:30:00"))
        controller.update(snapshot: snapshot, refreshDate: date, menuInput: makeMenuInput(), settings: settings(345))
        let after = controller.menuItemsForTesting.compactMap(\.view).flatMap(texts)
        XCTAssertTrue(after.contains("05:15:00"))
        XCTAssertFalse(after.contains("23:30:00"))
    }
}

extension StatusItemControllerTests {
    private func aggregationInput(count: Int, amount: Double = 4.73, date: Date = Date(timeIntervalSince1970: 1_700_000_000), summaries: [String: String] = [:], choices: [ProviderChoice]? = nil, notes: [Int: String] = [:]) -> StatusItemController.MenuInput {
        let displays = (0..<count).map { index -> AggregatedProviderDisplay in
            let id = "provider-\(index)"
            return AggregatedProviderDisplay(
                entry: AggregatedProviderEntry(source: ProviderSummarySource(id: id, name: "tokenshop",
                    isOfficial: false, query: nil, officialAccessToken: nil, notes: notes[index]), role: index == 0 ? .default : .member),
                identity: AggregationDisplayIdentity(providerID: id, accountScope: id, configurationRevision: "fixture"),
                snapshot: .balance("tokenshop", amount + Double(index), index == 1 ? "CNY" : "USD", nil, date, progressPercentage: nil),
                account: nil, status: .fresh, reason: nil, fetchedAt: date)
        }
        return StatusItemController.MenuInput(choices: choices ?? [ProviderChoice(id: "provider-0", name: "tokenshop", isCurrent: true)],
            quickSwitchSummaries: summaries, activeClient: .codex, openAIAccount: nil, statusLinks: [],
            showQuickSwitchMenu: true, showOpenChatGPTMenu: true, showOpenCCSwitchMenu: true, showStatusMenu: false,
            aggregatedProviders: displays, aggregationQuickSwitchBlocked: count > 0)
    }

    @MainActor
    func testAggregationUsesOneMenuViewWithSixDistinctBoundedCardsAndNativeFooter() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: aggregationInput(count: 6), settings: makeSettings())
        let menu = controller.statusMenuForTesting
        let scroll = try XCTUnwrap(menu.items.first?.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(document.subviews.count, 6)
        XCTAssertEqual(Set(document.subviews.compactMap { $0.identifier?.rawValue }).count, 6)
        XCTAssertLessThanOrEqual(scroll.frame.height, document.frame.height)
        XCTAssertLessThan(scroll.frame.height, NSScreen.main?.visibleFrame.height ?? 1000)
        XCTAssertTrue(menu.items.contains { $0.action != nil && $0.view == nil })
        let submenu = try XCTUnwrap(menu.items.first { $0.title == tr(.keyStatusItemControllerQuickSwitch) }?.submenu)
        XCTAssertTrue(submenu.items.filter { $0.representedObject is String }.allSatisfy { !$0.isEnabled && $0.state == .off })
        XCTAssertTrue(submenu.items.contains { $0.title == tr(.keyAggregationManageInCCSwitch) })
        for card in document.subviews {
            XCTAssertGreaterThan(card.frame.height, 60)
            XCTAssertEqual(card.frame.width, OpenCodexCardLayout.cardWidth)
            XCTAssertTrue(document.bounds.contains(card.frame))
        }
    }

    @MainActor
    func testAggregationValueRefreshKeepsViewsAndScrollWhileUpdatingEveryIdentity() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.overviewNumericReduceMotionForTesting = true
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: aggregationInput(count: 12), settings: makeSettings())
        let menu = controller.statusMenuForTesting
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let scroll = try XCTUnwrap(menu.items.first?.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let wrappers = document.subviews
        let cards = wrappers.map { $0.subviews.first { $0 is MenuHoverLinkHostView }! }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
        let origin = scroll.contentView.bounds.origin
        controller.updateMenu(input: aggregationInput(count: 12, amount: 14.73))
        XCTAssertTrue(menu.items.first?.view === scroll)
        XCTAssertTrue(zip(wrappers, document.subviews).allSatisfy { $0 === $1 })
        XCTAssertTrue(zip(cards, wrappers.map { $0.subviews.first { $0 is MenuHoverLinkHostView }! }).allSatisfy { $0 === $1 })
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 0.5)
        func numerics(_ view: NSView) -> [OverviewNumericTextView] {
            (view as? OverviewNumericTextView).map { [$0] } ?? view.subviews.flatMap(numerics)
        }
        let values = cards.flatMap(numerics)
        XCTAssertEqual(values.count, 12)
        XCTAssertEqual(Set(values.compactMap { $0.sample?.identity }).count, 12)
        XCTAssertEqual(Set(values.map(\.currentValue)), Set((0..<12).map { 14.73 + Double($0) }))
        controller.updateMenu(input: aggregationInput(count: 4, amount: 14.73))
        XCTAssertEqual(document.subviews.count, 4)
        XCTAssertTrue(document.subviews.allSatisfy { document.bounds.contains($0.frame) })
    }
}

extension StatusItemControllerTests {
    @MainActor
    func testAggregationExitWhileMenuOpenImmediatelyRestoresSingleCardAndQuickSwitch() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: aggregationInput(count: 4), settings: makeSettings())
        let menu = controller.statusMenuForTesting
        let originalRoot = menu.items.first?.view
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        controller.updateMenu(input: aggregationInput(count: 0))
        let retained = menu.items.first?.view as? NSScrollView
        XCTAssertNotNil(retained)
        XCTAssertTrue(retained?.documentView is MenuHoverLinkHostView)
        let quick = try XCTUnwrap(menu.items.first { $0.title == tr(.keyStatusItemControllerQuickSwitch) }?.submenu)
        XCTAssertFalse(quick.items.contains { $0.identifier?.rawValue == "aggregation.quickSwitch.hint" })
        XCTAssertTrue(quick.items.filter { $0.representedObject is String }.allSatisfy(\.isEnabled))
        XCTAssertTrue(menu.items.first?.view === originalRoot)
        controller.updateMenu(input: aggregationInput(count: 4))
        XCTAssertTrue(menu.items.first?.view === originalRoot)
        XCTAssertEqual((originalRoot as? NSScrollView)?.documentView?.subviews.count, 4)
    }
}

extension StatusItemControllerTests {
    @MainActor
    func testAggregationRepeatedEqualInputsKeepClosedAndOpenMenusAndNumericUpdatesDoNotReflow() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.overviewNumericReduceMotionForTesting = true
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: aggregationInput(count: 12), settings: makeSettings())
        let menu = controller.statusMenuForTesting
        let viewport = try XCTUnwrap(menu.items.first?.view)
        let rebuilds = controller.statusMenuRebuildCountForTesting
        let placements = controller.aggregationPlacementCountForTesting
        for _ in 0..<20 { controller.updateMenu(input: aggregationInput(count: 12)) }
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, rebuilds)
        XCTAssertEqual(controller.aggregationPlacementCountForTesting, placements)
        XCTAssertTrue(menu.items.first?.view === viewport)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        for _ in 0..<20 { controller.updateMenu(input: aggregationInput(count: 12)) }
        controller.updateMenu(input: aggregationInput(count: 12, amount: 14.73))
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, rebuilds)
        XCTAssertEqual(controller.aggregationPlacementCountForTesting, placements)
        XCTAssertTrue(menu.items.first?.view === viewport)
    }

    @MainActor
    func testAggregationCardsHaveNoBottomStatusSpaceAndStaleHintUsesExistingTimestamp() throws {
        let controller = makeController()
        defer { controller.teardown() }
        let original = aggregationInput(count: 4)
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: original, settings: makeSettings())
        let scroll = try XCTUnwrap(controller.statusMenuForTesting.items.first?.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        for wrapper in document.subviews {
            let host = try XCTUnwrap(wrapper.subviews.first { $0 is MenuHoverLinkHostView })
            XCTAssertEqual(host.frame.minY, 0)
            XCTAssertEqual(wrapper.frame.height, host.frame.height, accuracy: 0.5)
            XCTAssertFalse(wrapper.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Last updated" })
        }
        var displays = original.aggregatedProviders
        displays[1].status = .stale
        displays[1].reason = "Fixture network failure"
        let staleInput = StatusItemController.MenuInput(choices: original.choices, quickSwitchSummaries: [:], activeClient: .codex,
            openAIAccount: nil, statusLinks: [], showQuickSwitchMenu: true, showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true, showStatusMenu: false, aggregatedProviders: displays, aggregationQuickSwitchBlocked: true)
        controller.updateMenu(input: staleInput)
        let wrapper = try XCTUnwrap(document.subviews.first { $0.identifier?.rawValue == "aggregation.provider.provider-1" })
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        let time = try XCTUnwrap(fields(wrapper).first { $0.identifier?.rawValue == "overview.refreshTime" })
        XCTAssertTrue(time.stringValue.hasPrefix("⚠︎"))
        XCTAssertEqual(time.toolTip, "Fixture network failure")
        XCTAssertTrue(time.accessibilityLabel()?.contains("Fixture network failure") == true)
        XCTAssertEqual(wrapper.frame.height, wrapper.subviews.first { $0 is MenuHoverLinkHostView }?.frame.height)
    }

    @MainActor
    func testAggregationLinksOpenEachCardsOwnWebsiteAndSingleCardKeepsOriginalAction() throws {
        var opened: [URL] = []
        var currentWebsiteOpens = 0
        let controller = StatusItemController(actions: .init(manualRefresh: {}, openDashboard: {}, openChatGPT: {},
            openCCSwitch: {}, quit: {}, switchProvider: { _ in }, openProviderWebsite: { currentWebsiteOpens += 1 },
            openStatusLink: { opened.append($0) }, iconChanged: { _ in }))
        defer { controller.teardown() }
        let urls = [URL(string: "https://grok.example/billing")!, URL(string: "https://deepseek.example/balance")!,
            URL(string: "custom-scheme://example/billing")!, URL(string: "https://fixture:fixture@example/billing")!]
        var displays = aggregationInput(count: 4).aggregatedProviders
        for index in displays.indices {
            displays[index].snapshot = .balance("same-name", 4.73, "USD", urls[index], try XCTUnwrap(displays[index].fetchedAt), progressPercentage: nil)
        }
        let input = StatusItemController.MenuInput(choices: [], quickSwitchSummaries: [:], activeClient: .codex,
            openAIAccount: nil, statusLinks: [], showQuickSwitchMenu: false, showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false, showStatusMenu: false, aggregatedProviders: displays, aggregationQuickSwitchBlocked: true)
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: input, settings: makeSettings())
        func links(_ view: NSView) -> [HoverLinkTextField] { (view as? HoverLinkTextField).map { [$0] } ?? view.subviews.flatMap(links) }
        let scroll = try XCTUnwrap(controller.statusMenuForTesting.items.first?.view as? NSScrollView)
        let cards = try XCTUnwrap(scroll.documentView).subviews
        for index in cards.indices {
            if index < 2 { try XCTUnwrap(links(cards[index]).first).onActivate?() }
            else { XCTAssertTrue(links(cards[index]).isEmpty) }
        }
        XCTAssertEqual(opened, Array(urls.prefix(2)))
        XCTAssertEqual(currentWebsiteOpens, 0)
        controller.update(snapshot: displays[0].snapshot, refreshDate: displays[0].fetchedAt,
            menuInput: makeMenuInput(), settings: makeSettings())
        try XCTUnwrap(links(controller.statusMenuForTesting.items.first!.view!).first).onActivate?()
        XCTAssertEqual(currentWebsiteOpens, 1)
    }
}

extension StatusItemControllerTests {
    @MainActor
    func testClosedAggregationValuesArePreparedWithoutRebuildAndProgressLayoutRespondsToSettings() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.overviewNumericReduceMotionForTesting = true
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: aggregationInput(count: 2), settings: makeSettings())
        let menu = controller.statusMenuForTesting
        let scroll = try XCTUnwrap(menu.items.first?.view as? NSScrollView)
        let root = try XCTUnwrap(scroll.documentView)
        func values(_ view: NSView) -> [OverviewNumericTextView] {
            (view as? OverviewNumericTextView).map { [$0] } ?? view.subviews.flatMap(values)
        }
        controller.updateMenu(input: aggregationInput(count: 2, amount: 14.73))
        XCTAssertEqual(Set(values(root).map(\.currentValue)), Set([14.73, 15.73]))
        XCTAssertFalse(values(root).contains(where: \.isDigitRollingForTesting))
        XCTAssertTrue(menu.items.first?.view === scroll)
        var displays = aggregationInput(count: 2).aggregatedProviders
        for i in displays.indices {
            displays[i].snapshot = .balance(displays[i].snapshot.provider, 4.73, "USD", nil,
                try XCTUnwrap(displays[i].fetchedAt), progressPercentage: 50)
        }
        let input = StatusItemController.MenuInput(choices: [], quickSwitchSummaries: [:], activeClient: .codex,
            openAIAccount: nil, statusLinks: [], showQuickSwitchMenu: false, showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false, showStatusMenu: false, aggregatedProviders: displays)
        controller.updateMenu(input: input)
        func progress(_ view: NSView) -> [QuotaProgressView] {
            (view as? QuotaProgressView).map { [$0] } ?? view.subviews.flatMap(progress)
        }
        XCTAssertEqual(progress(root).count, 2)
        let settings = StatusItemController.MenuBarSettings(showIcon: true, showAmount: true, showReset: true,
            horizontalPadding: 6, keepMenuOpenAfterRefresh: true, showQuotaProgressBar: false)
        controller.update(snapshot: .placeholder, refreshDate: nil, menuInput: input, settings: settings)
        XCTAssertTrue(progress(root).isEmpty)
    }
}

extension StatusItemControllerTests {
    @MainActor
    func testAggregationWindowMountRepairsOutOfRangeViewportAndKeepsVisibleCardsAfterLifecycleUpdates() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: aggregationInput(count: 12), settings: makeSettings())
        let menu = controller.statusMenuForTesting
        let scroll = try XCTUnwrap(menu.items.first?.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: scroll.frame.width, height: scroll.frame.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { scroll.removeFromSuperview(); window.close() }
        func mountAndAssertVisible() {
            window.contentView?.addSubview(scroll)
            window.contentView?.layoutSubtreeIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            XCTAssertTrue(scroll.window === window)
            XCTAssertGreaterThan(scroll.contentView.bounds.width, 0)
            XCTAssertGreaterThan(scroll.contentView.bounds.height, 0)
            let visible = scroll.contentView.documentVisibleRect
            XCTAssertTrue(document.subviews.contains {
                let card = $0.subviews.first { !($0 is NSTextField) } ?? $0
                return !$0.isHidden && !card.isHidden && !document.convert(card.bounds, from: card).intersection(visible).isEmpty
            },
                "mounted viewport must intersect a real card: \(visible)")
        }
        // Reattachment can expose an obsolete clip offset before AppKit lays out.
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: document.frame.height + 100))
        mountAndAssertVisible()
        controller.menuWillOpen(menu)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
        controller.updateMenu(input: aggregationInput(count: 12, amount: 9.12))
        scroll.frame.size.height = 120
        scroll.tile()
        mountAndAssertVisible()
        controller.menuDidClose(menu)
        scroll.removeFromSuperview()
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: document.frame.height + 100))
        mountAndAssertVisible()
        controller.menuWillOpen(menu)
        controller.updateMenu(input: aggregationInput(count: 4))
        mountAndAssertVisible()
        controller.menuDidClose(menu)
    }
}


extension StatusItemControllerTests {
    @MainActor
    func testQuickSwitchSummaryOnlyUpdatesRetainMenuItemsAndMountedOverviewAcrossOpenClose() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: aggregationInput(count: 4), settings: makeSettings())
        let menu = controller.statusMenuForTesting
        let root = menu.items.first?.view
        let quick = try XCTUnwrap(menu.items.first { $0.title == tr(.keyStatusItemControllerQuickSwitch) }?.submenu)
        let row = try XCTUnwrap(quick.items.first { $0.representedObject as? String == "provider-0" })
        let rebuilds = controller.statusMenuRebuildCountForTesting
        let placements = controller.aggregationPlacementCountForTesting
        for index in 0..<20 {
            controller.updateMenu(input: aggregationInput(count: 4, summaries: ["provider-0": "$\(index).73"]))
        }
        XCTAssertTrue(row.attributedTitle?.string.contains("$19.73") == true)
        controller.menuWillOpen(menu)
        controller.updateMenu(input: aggregationInput(count: 4, summaries: ["provider-0": "$20.73"]))
        controller.menuDidClose(menu)
        controller.menuWillOpen(menu)
        XCTAssertTrue(menu.items.first?.view === root)
        XCTAssertTrue(quick.items.contains { $0 === row })
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, rebuilds)
        XCTAssertEqual(controller.aggregationPlacementCountForTesting, placements)
        controller.menuDidClose(menu)
    }

    @MainActor
    func testDeferredStructureRebuildSurvivesImmediateReopenAndRunsOnlyAfterClose() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: aggregationInput(count: 4), settings: makeSettings())
        let menu = controller.statusMenuForTesting
        let root = menu.items.first?.view
        let before = controller.statusMenuRebuildCountForTesting
        let choices = [ProviderChoice(id: "provider-0", name: "tokenshop", isCurrent: true), ProviderChoice(id: "new", name: "new", isCurrent: false)]
        controller.menuWillOpen(menu)
        controller.updateMenu(input: aggregationInput(count: 4, choices: choices))
        controller.menuDidClose(menu)
        controller.menuWillOpen(menu)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(menu.items.first?.view === root)
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, before)
        controller.menuDidClose(menu)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, before + 1)
        let quick = try XCTUnwrap(menu.items.first { $0.title == tr(.keyStatusItemControllerQuickSwitch) }?.submenu)
        XCTAssertTrue(quick.items.contains { $0.representedObject as? String == "new" })
    }

    @MainActor
    func testAggregationNotesMeasuredWithoutDefaultFooterAndChangingNotesKeepsCard() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.start(snapshot: .placeholder, refreshDate: nil, menuInput: aggregationInput(count: 4), settings: makeSettings())
        let scroll = try XCTUnwrap(controller.statusMenuForTesting.items.first?.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let wrapper = document.subviews[0]
        let card = try XCTUnwrap(wrapper.subviews.first { $0 is MenuHoverLinkHostView })
        XCTAssertEqual(wrapper.frame.height, card.frame.height)
        let notes = "Fixture note with a long second line. " + String(repeating: "note ", count: 40)
        controller.updateMenu(input: aggregationInput(count: 4, notes: [0: notes]))
        XCTAssertTrue(wrapper.subviews.contains { $0 === card })
        let label = try XCTUnwrap(wrapper.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "aggregation.notes" })
        XCTAssertEqual(label.toolTip, notes)
        XCTAssertFalse(label.isHidden)
        XCTAssertGreaterThan(wrapper.frame.height, card.frame.height)
        XCTAssertLessThanOrEqual(wrapper.frame.height - card.frame.height, 54)
        controller.updateMenu(input: aggregationInput(count: 4))
        XCTAssertEqual(wrapper.frame.height, card.frame.height)
        XCTAssertTrue(label.isHidden)
    }
}
