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
    func testRuntimeDisplayPolicyPublishesAndClearsItsWarningImmediately() {
        var visibilityTransitions: [StatusItemVisibility] = []
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
                iconChanged: { _ in },
                visibilityChanged: { visibilityTransitions.append($0) }
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
            openAIAccount: nil,
            statusLinks: [],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showOpenCodexMenu: true,
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
}
