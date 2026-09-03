import AppKit
import XCTest
@testable import BalanceBar

final class AppDelegateCompositionTests: XCTestCase {
    func testAppDelegateBoundaryContainsOnlyCompositionResponsibilities() throws {
        let source = try balanceBarSource()
        let appDelegateStart = try XCTUnwrap(
            source.range(of: "final class AppDelegate: NSObject, NSApplicationDelegate")
        )
        let appDelegateEnd = try XCTUnwrap(
            source.range(of: "struct ApplicationLifecycleStats", range: appDelegateStart.upperBound..<source.endIndex)
        )
        let appDelegateSource = String(source[appDelegateStart.lowerBound..<appDelegateEnd.lowerBound])

        XCTAssertFalse(appDelegateSource.contains("sqlite3"))
        XCTAssertFalse(appDelegateSource.contains("URLSession"))
        XCTAssertFalse(appDelegateSource.contains("NSView("))
        XCTAssertFalse(appDelegateSource.contains("NSWindow("))
        XCTAssertFalse(appDelegateSource.contains("NSView"))
        XCTAssertFalse(appDelegateSource.contains("DispatchSource"))
        XCTAssertFalse(appDelegateSource.contains("CodexActivityMonitor"))
        XCTAssertFalse(appDelegateSource.contains("ClaudeCodeActivityMonitor"))
        XCTAssertFalse(appDelegateSource.contains("fetchBalance"))
        XCTAssertFalse(appDelegateSource.contains("fetchQuota"))
        XCTAssertFalse(appDelegateSource.contains("makeDashboardPage"))
        XCTAssertFalse(appDelegateSource.contains("makeSectionPage"))
        XCTAssertFalse(appDelegateSource.contains("fetchBalance"))
        XCTAssertFalse(appDelegateSource.contains("refreshCodexActivity"))
        XCTAssertFalse(source.contains("BalanceBarApplicationCoordinator"))
    }

    func testAutomaticUpdateStateRefreshDoesNotPresentReleaseNotes() throws {
        let source = try balanceBarSource()
        let handlerStart = try XCTUnwrap(source.range(of: "self.updateService.onStateChange"))
        let handlerEnd = try XCTUnwrap(
            source.range(of: "databaseWatcher = CCSwitchDatabaseWatcher", range: handlerStart.upperBound..<source.endIndex)
        )
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        XCTAssertTrue(handler.contains("refreshUpdateState"))
        XCTAssertTrue(handler.contains("refreshStatusItemMenuInput"))
        XCTAssertFalse(
            handler.contains("showUpdateNotes"),
            "automatic update state changes must refresh presentation only; release notes require the explicit button action"
        )
    }

    func testAvailableStateIsTheOnlySourceOfTheStatusMenuBadgePresentation() throws {
        let source = try balanceBarSource()
        let propertyStart = try XCTUnwrap(source.range(of: "private var showsAvailableUpdateBadge: Bool"))
        let propertyEnd = try XCTUnwrap(
            source.range(of: "private func currentProviderName()", range: propertyStart.upperBound..<source.endIndex)
        )
        let property = String(source[propertyStart.lowerBound..<propertyEnd.lowerBound])

        XCTAssertTrue(property.contains("if case .available = updateService.state"))
        XCTAssertFalse(property.contains("availableReleaseForPresentation"))
        XCTAssertFalse(property.contains("latest > current"))
    }

    func testCompositionLayerOwnsConcreteResponsibilitiesByModule() throws {
        let sources = try compositionSources()
        let dashboard = try XCTUnwrap(sources["DashboardCompositionController.swift"])
        XCTAssertTrue(dashboard.contains("DashboardWindowController"))
        XCTAssertTrue(dashboard.contains("DashboardPreferencePages"))
        XCTAssertTrue(dashboard.contains("DashboardProviderPageCoordinator"))
        XCTAssertTrue(dashboard.contains("makeSectionPage"))
        XCTAssertTrue(dashboard.contains("StatusLinksEditorHostingView"))

        let provider = try XCTUnwrap(sources["ProviderRefreshCoordinator.swift"])
        XCTAssertTrue(provider.contains("BalanceAPIClient"))
        XCTAssertTrue(provider.contains("OfficialQuotaClient"))
        XCTAssertTrue(provider.contains("fetchBalance"))

        let openCodex = try XCTUnwrap(sources["OpenCodexRefreshCoordinator.swift"])
        XCTAssertTrue(openCodex.contains("OpenCodexRepository"))
        XCTAssertTrue(openCodex.contains("OpenCodexCardPlanner"))
        XCTAssertTrue(openCodex.contains("fetchOfficialCard"))

        let activity = try XCTUnwrap(sources["ActivityCoordinator.swift"])
        XCTAssertTrue(activity.contains("CodexActivityMonitor"))
        XCTAssertTrue(activity.contains("ClaudeCodeActivityMonitor"))
        XCTAssertTrue(activity.contains("NSWorkspace"))

        let watcher = try XCTUnwrap(sources["CCSwitchDatabaseWatcher.swift"])
        XCTAssertTrue(watcher.contains("DispatchSource"))
        XCTAssertTrue(watcher.contains("O_EVTONLY"))

        let switching = try XCTUnwrap(sources["ProviderSwitchCoordinator.swift"])
        XCTAssertTrue(switching.contains("switchCurrent"))
        XCTAssertTrue(switching.contains("com.ccswitch.desktop"))
    }

    @MainActor
    func testMenuBarWidthCoalescerFlushesLatestValueAndCancelsPendingWork() {
        var applied: [CGFloat] = []
        let coalescer = MenuBarWidthDisplayCoalescer { applied.append($0) }

        coalescer.submit(3.1)
        coalescer.submit(7.4)
        coalescer.flush()

        XCTAssertEqual(applied, [7.4])

        coalescer.submit(12.6)
        coalescer.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(applied, [7.4])
    }

    func testLifecycleGateInstallsAndTearsDownExactlyOnce() {
        let lifecycle = ApplicationLifecycleState()

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertFalse(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.beginTerminate())
        XCTAssertFalse(lifecycle.beginTerminate())
        XCTAssertFalse(lifecycle.beginStart())
        XCTAssertEqual(
            lifecycle.stats,
            ApplicationLifecycleStats(startCount: 1, terminateCount: 1)
        )
    }

    func testStatusItemVisibilityRequiresRenderedEvidenceAndStableOverflow() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let visibleFrame = NSRect(x: 840, y: 780, width: 100, height: 20)
        let overflowFrame = NSRect(x: 940, y: 780, width: 100, height: 20)
        let nonMenuBarFrame = NSRect(x: 940, y: 720, width: 100, height: 20)
        let statusItem = NSObject()
        let window = NSObject()
        let button = NSObject()
        let start = Date(timeIntervalSince1970: 1_000)

        func evidence(
            window: NSObject?,
            occlusionVisible: Bool,
            frame: NSRect?,
            statusItemIsVisible: Bool = true,
            windowIsVisible: Bool = true,
            buttonIsHidden: Bool = false
        ) -> StatusItemVisibilityEvidence {
            StatusItemVisibilityEvidence(
                statusItemIsVisible: statusItemIsVisible,
                windowIsVisible: windowIsVisible,
                windowIsOcclusionVisible: occlusionVisible,
                statusItemIdentity: ObjectIdentifier(statusItem),
                windowIdentity: window.map(ObjectIdentifier.init),
                buttonIdentity: ObjectIdentifier(button),
                statusItemFrame: frame,
                statusItemWindowFrame: frame,
                screenFrame: screen,
                buttonIsHidden: buttonIsHidden
            )
        }

        var machine = StatusItemVisibilityStateMachine()
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: true, frame: visibleFrame),
                at: start
            ),
            .visible
        )

        // A complete frame inside the screen is not enough to prove that
        // WindowServer is actually drawing this item.
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: false, frame: visibleFrame),
                at: start.addingTimeInterval(0.2)
            ),
            .visible
        )
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: false, frame: visibleFrame),
                at: start.addingTimeInterval(0.4)
            ),
            .hiddenByMenuBarSpace
        )

        // Real occlusion-visible evidence clears a candidate and any warning
        // immediately after menu-bar reflow.
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: true, frame: visibleFrame),
                at: start.addingTimeInterval(0.5)
            ),
            .visible
        )

        // A genuine horizontal overflow still requires stable confirmation.
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: false, frame: overflowFrame),
                at: start.addingTimeInterval(0.6)
            ),
            .visible
        )
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: false, frame: overflowFrame),
                at: start.addingTimeInterval(0.8)
            ),
            .hiddenByMenuBarSpace
        )

        var unknownMachine = StatusItemVisibilityStateMachine()
        XCTAssertEqual(
            unknownMachine.ingest(
                evidence(window: nil, occlusionVisible: false, frame: visibleFrame),
                at: start
            ),
            .unknown
        )
        XCTAssertEqual(
            unknownMachine.ingest(
                evidence(window: window, occlusionVisible: true, frame: nonMenuBarFrame),
                at: start.addingTimeInterval(0.2)
            ),
            .unknown
        )
        XCTAssertEqual(
            unknownMachine.ingest(
                evidence(window: window, occlusionVisible: true, frame: nil),
                at: start.addingTimeInterval(0.4)
            ),
            .unknown
        )
        XCTAssertEqual(
            unknownMachine.ingest(
                evidence(
                    window: window,
                    occlusionVisible: false,
                    frame: visibleFrame,
                    statusItemIsVisible: false
                ),
                at: start.addingTimeInterval(0.5)
            ),
            .unknown
        )
        XCTAssertEqual(
            unknownMachine.ingest(
                evidence(
                    window: window,
                    occlusionVisible: false,
                    frame: visibleFrame,
                    windowIsVisible: false
                ),
                at: start.addingTimeInterval(0.6)
            ),
            .unknown
        )
    }

    func testStatusItemVisibilityRejectsAnalyzerGeometryOnlyEvidence() {
        let screen = NSRect(x: 0, y: 0, width: 1_710, height: 1_112)
        let analyzerFrame = NSRect(x: 894, y: 1_081.5, width: 69, height: 22)
        let analyzerWindowFrame = NSRect(x: 886, y: 1_081.5, width: 85, height: 30)
        let statusItem = NSObject()
        let window = NSObject()
        let button = NSObject()
        let start = Date(timeIntervalSince1970: 3_000)

        func evidence(occlusionVisible: Bool) -> StatusItemVisibilityEvidence {
            StatusItemVisibilityEvidence(
                statusItemIsVisible: true,
                windowIsVisible: true,
                windowIsOcclusionVisible: occlusionVisible,
                statusItemIdentity: ObjectIdentifier(statusItem),
                windowIdentity: ObjectIdentifier(window),
                buttonIdentity: ObjectIdentifier(button),
                statusItemFrame: analyzerFrame,
                statusItemWindowFrame: analyzerWindowFrame,
                screenFrame: screen,
                buttonIsHidden: false
            )
        }

        var machine = StatusItemVisibilityStateMachine()
        XCTAssertEqual(machine.ingest(evidence(occlusionVisible: false), at: start), .unknown)
        XCTAssertEqual(
            machine.ingest(
                evidence(occlusionVisible: false),
                at: start.addingTimeInterval(0.2)
            ),
            .hiddenByMenuBarSpace
        )
        XCTAssertEqual(
            machine.ingest(
                evidence(occlusionVisible: true),
                at: start.addingTimeInterval(0.3)
            ),
            .visible
        )
    }

    func testStatusItemVisibilityRecoversFromOverflowToVisibleAndUnknown() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let visibleFrame = NSRect(x: 840, y: 780, width: 100, height: 20)
        let overflowFrame = NSRect(x: 940, y: 780, width: 100, height: 20)
        let statusItem = NSObject()
        let window = NSObject()
        let replacementWindow = NSObject()
        let button = NSObject()
        let start = Date(timeIntervalSince1970: 2_000)

        func evidence(
            window: NSObject?,
            occlusionVisible: Bool,
            frame: NSRect?,
            buttonIsHidden: Bool = false
        ) -> StatusItemVisibilityEvidence {
            StatusItemVisibilityEvidence(
                statusItemIsVisible: true,
                windowIsVisible: true,
                windowIsOcclusionVisible: occlusionVisible,
                statusItemIdentity: ObjectIdentifier(statusItem),
                windowIdentity: window.map(ObjectIdentifier.init),
                buttonIdentity: ObjectIdentifier(button),
                statusItemFrame: frame,
                statusItemWindowFrame: frame,
                screenFrame: screen,
                buttonIsHidden: buttonIsHidden
            )
        }

        var machine = StatusItemVisibilityStateMachine()
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: false, frame: overflowFrame),
                at: start
            ),
            .unknown
        )
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: false, frame: overflowFrame),
                at: start.addingTimeInterval(0.2)
            ),
            .hiddenByMenuBarSpace
        )
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: true, frame: visibleFrame),
                at: start.addingTimeInterval(0.4)
            ),
            .visible
        )

        // Window replacement cannot inherit a stale hidden warning.
        XCTAssertEqual(
            machine.ingest(
                evidence(window: replacementWindow, occlusionVisible: true, frame: visibleFrame),
                at: start.addingTimeInterval(0.5)
            ),
            .visible
        )
        XCTAssertEqual(
            machine.ingest(
                evidence(window: nil, occlusionVisible: false, frame: nil),
                at: start.addingTimeInterval(0.6)
            ),
            .unknown
        )
        XCTAssertEqual(
            machine.ingest(
                evidence(window: window, occlusionVisible: true, frame: visibleFrame),
                at: start.addingTimeInterval(0.7)
            ),
            .visible
        )
    }

    func testStatusItemVisibilityKeepsCommittedHiddenDuringGeometryChurn() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let overflowFrames = [
            NSRect(x: 940, y: 780, width: 100, height: 20),
            NSRect(x: 941, y: 780, width: 100, height: 20),
            NSRect(x: 942, y: 780, width: 100, height: 20),
            NSRect(x: 943, y: 780, width: 100, height: 20)
        ]
        let visibleFrame = NSRect(x: 840, y: 780, width: 100, height: 20)
        let statusItem = NSObject()
        let window = NSObject()
        let button = NSObject()
        let start = Date(timeIntervalSince1970: 4_000)

        func evidence(
            frame: NSRect,
            occlusionVisible: Bool = false,
            windowObject: NSObject?
        ) -> StatusItemVisibilityEvidence {
            StatusItemVisibilityEvidence(
                statusItemIsVisible: true,
                windowIsVisible: true,
                windowIsOcclusionVisible: occlusionVisible,
                statusItemIdentity: ObjectIdentifier(statusItem),
                windowIdentity: windowObject.map(ObjectIdentifier.init),
                buttonIdentity: ObjectIdentifier(button),
                statusItemFrame: frame,
                statusItemWindowFrame: frame,
                screenFrame: screen,
                buttonIsHidden: false
            )
        }

        var machine = StatusItemVisibilityStateMachine()
        var publishedTransitions: [StatusItemVisibility] = []

        func ingest(_ evidence: StatusItemVisibilityEvidence, at date: Date) -> StatusItemVisibility {
            let state = machine.ingest(evidence, at: date)
            if publishedTransitions.last != state {
                publishedTransitions.append(state)
            }
            return state
        }

        XCTAssertEqual(
            ingest(evidence(frame: overflowFrames[0], windowObject: window), at: start),
            .unknown
        )
        XCTAssertEqual(
            ingest(
                evidence(frame: overflowFrames[0], windowObject: window),
                at: start.addingTimeInterval(0.2)
            ),
            .hiddenByMenuBarSpace
        )
        XCTAssertFalse(machine.needsAdditionalHiddenSample)

        // Slider/layout churn changes the raw candidate signature. It must
        // replace pending evidence without publishing hidden -> unknown.
        for (index, frame) in overflowFrames.dropFirst().enumerated() {
            XCTAssertEqual(
                ingest(
                    evidence(frame: frame, windowObject: window),
                    at: start.addingTimeInterval(0.4 + Double(index) * 0.2)
                ),
                .hiddenByMenuBarSpace
            )
            XCTAssertTrue(machine.needsAdditionalHiddenSample)
        }
        XCTAssertEqual(
            ingest(
                evidence(frame: overflowFrames.last!, windowObject: window),
                at: start.addingTimeInterval(1.2)
            ),
            .hiddenByMenuBarSpace
        )
        XCTAssertFalse(machine.needsAdditionalHiddenSample)
        XCTAssertEqual(
            publishedTransitions,
            [.unknown, .hiddenByMenuBarSpace],
            "pending geometry samples must not emit hidden -> unknown -> hidden"
        )

        // A real rendered sample still recovers immediately after reflow.
        XCTAssertEqual(
            ingest(
                evidence(frame: visibleFrame, occlusionVisible: true, windowObject: window),
                at: start.addingTimeInterval(1.3)
            ),
            .visible
        )

        // Explicit invalid evidence and lifecycle reset still clear the
        // committed state instead of preserving a stale warning.
        XCTAssertEqual(
            ingest(
                evidence(frame: visibleFrame, windowObject: nil),
                at: start.addingTimeInterval(1.4)
            ),
            .unknown
        )
        machine.reset()
        XCTAssertEqual(machine.visibility, .unknown)
        XCTAssertFalse(machine.needsAdditionalHiddenSample)
    }

    func testMenuBarIconDisplayStateMachineDebouncesIdleAndRecoversImmediately() {
        var machine = MenuBarIconDisplayStateMachine()
        let start = Date(timeIntervalSince1970: 2_000)
        let delay = MenuBarIconDisplayDelay.tenSeconds

        XCTAssertTrue(
            machine.ingest(
                mode: .alwaysVisible,
                displayDelay: delay,
                codexTaskRunning: false,
                at: start
            )
        )
        XCTAssertEqual(machine.idleCandidateSampleCount, 0)

        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: delay,
                codexTaskRunning: false,
                at: start
            ),
            "the first idle sample must not hide the item"
        )
        XCTAssertTrue(machine.needsAdditionalIdleSample)
        XCTAssertTrue(
            machine.setMode(
                .onlyWhileRunning,
                codexTaskRunning: false,
                at: start.addingTimeInterval(1)
            ),
            "reapplying the same mode must not count as another activity sample"
        )
        XCTAssertEqual(machine.idleCandidateSampleCount, 1)
        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: delay,
                codexTaskRunning: false,
                at: start.addingTimeInterval(
                    MenuBarIconDisplayStateMachine.idleConfirmationInterval / 2
                )
            ),
            "a short-lived idle sample must keep the item visible"
        )
        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: delay,
                codexTaskRunning: false,
                at: start.addingTimeInterval(
                    MenuBarIconDisplayStateMachine.idleConfirmationInterval
                )
            ),
            "stable idle must remain visible during the selected grace period"
        )
        XCTAssertTrue(machine.shouldDisplay)
        XCTAssertFalse(machine.needsAdditionalIdleSample)

        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: delay,
                codexTaskRunning: false,
                at: start.addingTimeInterval(delay.duration - 0.01)
            ),
            "the item must not hide before the selected grace period elapses"
        )
        XCTAssertFalse(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: delay,
                codexTaskRunning: false,
                at: start.addingTimeInterval(delay.duration)
            ),
            "stable idle must hide once the selected grace period elapses"
        )
        XCTAssertFalse(machine.shouldDisplay)

        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: delay,
                codexTaskRunning: true,
                at: start.addingTimeInterval(0.4)
            ),
            "a running sample must show the item immediately"
        )
        XCTAssertTrue(machine.shouldDisplay)

        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: delay,
                codexTaskRunning: false,
                at: start.addingTimeInterval(0.5)
            ),
            "a new idle candidate starts visible after recovery"
        )
        XCTAssertTrue(
            machine.ingest(
                mode: .alwaysVisible,
                displayDelay: delay,
                codexTaskRunning: false,
                at: start.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(machine.idleCandidateSampleCount, 0)
    }

    func testMenuBarIconDisplayDelayChangesCommitOnlyAnAlreadyStableIdleCandidate() {
        var machine = MenuBarIconDisplayStateMachine()
        let start = Date(timeIntervalSince1970: 3_000)

        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: .threeMinutes,
                codexTaskRunning: false,
                at: start
            )
        )
        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: .threeMinutes,
                codexTaskRunning: false,
                at: start.addingTimeInterval(
                    MenuBarIconDisplayStateMachine.idleConfirmationInterval
                )
            )
        )
        XCTAssertEqual(machine.idleCandidateSampleCount, 2)

        XCTAssertTrue(
            machine.setDisplayDelay(
                .threeMinutes,
                at: start.addingTimeInterval(120)
            ),
            "changing the delay must not add an activity sample"
        )
        XCTAssertEqual(machine.idleCandidateSampleCount, 2)
        XCTAssertFalse(
            machine.setDisplayDelay(
                .zeroSeconds,
                at: start.addingTimeInterval(120)
            ),
            "selecting zero delay may commit an already stable elapsed candidate immediately"
        )
        XCTAssertFalse(machine.shouldDisplay)
        XCTAssertEqual(machine.idleCandidateSampleCount, 2)
    }

    func testMenuBarIconDisplayZeroDelayStillRequiresStableIdleSamples() {
        var machine = MenuBarIconDisplayStateMachine()
        let start = Date(timeIntervalSince1970: 4_000)

        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: .zeroSeconds,
                codexTaskRunning: false,
                at: start
            ),
            "zero delay keeps the item visible after the first idle sample"
        )
        XCTAssertEqual(machine.idleCandidateSampleCount, 1)

        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: .zeroSeconds,
                codexTaskRunning: false,
                at: start.addingTimeInterval(
                    MenuBarIconDisplayStateMachine.idleConfirmationInterval / 2
                )
            ),
            "zero delay still ignores a too-short idle interval"
        )
        XCTAssertTrue(machine.shouldDisplay)

        XCTAssertFalse(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: .zeroSeconds,
                codexTaskRunning: false,
                at: start.addingTimeInterval(
                    MenuBarIconDisplayStateMachine.idleConfirmationInterval
                )
            ),
            "zero delay hides after the second stable idle sample"
        )
        XCTAssertFalse(machine.shouldDisplay)
        XCTAssertEqual(machine.idleCandidateSampleCount, 2)

        XCTAssertTrue(
            machine.ingest(
                mode: .onlyWhileRunning,
                displayDelay: .zeroSeconds,
                codexTaskRunning: true,
                at: start.addingTimeInterval(1)
            ),
            "a new task still restores the item immediately"
        )
        XCTAssertTrue(machine.shouldDisplay)
    }

    @MainActor
    func testStatusItemStartIsIdempotentAndTeardownIsSafe() throws {
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
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true,
            fontSize: 14.2
        )

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: settings
        )
        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: settings
        )
        XCTAssertEqual(controller.statusItemInstallCount, 1)
        XCTAssertEqual(
            controller.menuBarFontPointSizesForTesting?.primary ?? .nan,
            14.2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.menuBarFontPointSizesForTesting?.secondary ?? .nan,
            14.2 * AppPreferences.menuBarSecondaryToPrimaryFontRatio,
            accuracy: 0.001
        )

        let initialLength = try XCTUnwrap(controller.statusItemLengthForTesting)
        let menuItemIdentities = controller.menuItemsForTesting.map { ObjectIdentifier($0) }
        controller.updateWidthAdjustment(10)
        controller.updateWidthAdjustment(20)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            controller.statusItemLengthForTesting ?? .nan,
            initialLength + 20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.menuItemsForTesting.map { ObjectIdentifier($0) },
            menuItemIdentities,
            "continuous width updates must not rebuild the status menu"
        )

        controller.updateFontSize(CGFloat(MenuBarFontSizePreset.small.primarySize))
        XCTAssertEqual(
            controller.menuBarFontPointSizesForTesting?.primary ?? .nan,
            MenuBarFontSizePreset.small.primarySize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.menuBarFontPointSizesForTesting?.secondary ?? .nan,
            MenuBarFontSizePreset.small.secondarySize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.menuItemsForTesting.map { ObjectIdentifier($0) },
            menuItemIdentities,
            "font-size updates must not rebuild the status menu"
        )

        controller.teardown()
        controller.teardown()
    }

    @MainActor
    func testStatusMenuReusesItemsForUnchangedMenuInput() {
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
            choices: [ProviderChoice(id: "provider", name: "Provider", isCurrent: true)],
            quickSwitchSummaries: ["provider": "$1.00"],
            activeClient: .codex,
            openAIAccount: nil,
            statusLinks: [StatusLink(title: "Status", url: "https://status.example")],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showOpenCodexMenu: true,
            showStatusMenu: true
        )
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: settings
        )
        let initialItems = controller.menuItemsForTesting.map { ObjectIdentifier($0) }

        controller.updateMenu(input: input)

        XCTAssertEqual(
            controller.menuItemsForTesting.map { ObjectIdentifier($0) },
            initialItems,
            "a repeated menu input must not rebuild the status menu"
        )
    }

    @MainActor
    func testStatusMenuShowsLocalizedNativeBadgeAndDefersTrackingRebuilds() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

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
        let withoutUpdate = makeStatusMenuInput(showsAvailableUpdateBadge: false)
        let withUpdate = makeStatusMenuInput(showsAvailableUpdateBadge: true)
        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: withoutUpdate,
            settings: settings
        )

        func openMainWindowItem() throws -> NSMenuItem {
            try XCTUnwrap(
                controller.menuItemsForTesting.first {
                    $0.title == tr(.keyStatusItemControllerOpenMainWindow)
                }
            )
        }

        var item = try openMainWindowItem()
        XCTAssertNil(item.badge)
        XCTAssertNil(item.view)
        let initialIDs = controller.menuItemsForTesting.map { ObjectIdentifier($0) }

        controller.updateMenu(input: withoutUpdate)
        XCTAssertEqual(
            controller.menuItemsForTesting.map { ObjectIdentifier($0) },
            initialIDs,
            "unchanged presentation input must not rebuild the menu"
        )

        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.updateMenu(input: withUpdate)
        XCTAssertEqual(
            controller.menuItemsForTesting.map { ObjectIdentifier($0) },
            initialIDs,
            "a state change during menu tracking must be deferred"
        )
        XCTAssertNil(try openMainWindowItem().badge)

        controller.menuDidClose(controller.statusMenuForTesting)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        item = try openMainWindowItem()
        XCTAssertNotNil(item.badge)
        XCTAssertEqual(
            item.badge?.stringValue,
            tr(.keyStatusItemControllerUpdateAvailableBadge)
        )
        XCTAssertNil(item.view, "the update prompt must use AppKit's badge, not a custom menu view")
        let availableIDs = controller.menuItemsForTesting.map { ObjectIdentifier($0) }

        controller.updateMenu(input: withUpdate)
        XCTAssertEqual(
            controller.menuItemsForTesting.map { ObjectIdentifier($0) },
            availableIDs,
            "repeated available presentation must not rebuild the menu"
        )

        controller.updateMenu(input: withoutUpdate)
        item = try openMainWindowItem()
        XCTAssertNil(item.badge, "handled or ignored updates must remove the badge")
        XCTAssertNotEqual(
            controller.menuItemsForTesting.map { ObjectIdentifier($0) },
            availableIDs
        )
    }

    @MainActor
    func testSilentStartupChecksUpdatesAndSchedulesIndependentBackgroundTimer() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousSilentLaunch = defaults.object(forKey: AppPreferences.silentLaunchKey)
        defer {
            if let previousSilentLaunch {
                defaults.set(previousSilentLaunch, forKey: AppPreferences.silentLaunchKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.silentLaunchKey)
            }
        }
        defaults.set(true, forKey: AppPreferences.silentLaunchKey)

        let ignoreSuiteName = "AppDelegateCompositionTests.update-badge.\(UUID().uuidString)"
        let ignoreDefaults = try XCTUnwrap(UserDefaults(suiteName: ignoreSuiteName))
        defer { ignoreDefaults.removePersistentDomain(forName: ignoreSuiteName) }

        let fetcher = StartupUpdateReleaseFetcher()
        let service = UpdateService(
            releaseFetcher: fetcher,
            currentVersionString: "1.2.0",
            callbackQueue: .main,
            workQueue: .main,
            minimumCheckingDuration: 0,
            automaticCheckMinimumInterval: 0,
            ignoredVersionStore: UserDefaultsUpdateVersionIgnoreStore(defaults: ignoreDefaults)
        )
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-276-startup.db")
            ),
            updateService: service
        )
        defer {
            appDelegate.applicationWillTerminate(
                Notification(name: NSApplication.willTerminateNotification)
            )
        }

        appDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        XCTAssertFalse(
            appDelegate.dashboardCompositionForTesting.isVisible,
            "silent startup must not rely on opening the Dashboard to check updates"
        )
        XCTAssertEqual(fetcher.requestCount, 1, "silent startup must initiate one automatic update check")
        XCTAssertEqual(
            appDelegate.backgroundUpdateTimerForTesting?.timeInterval,
            AppDelegate.backgroundUpdateCheckInterval,
            "the background update timer must use the independent six-hour cadence"
        )
        XCTAssertEqual(AppDelegate.backgroundUpdateCheckInterval, 6 * 60 * 60)

        fetcher.resolve(.success([
            GitHubRelease(
                tagName: "v1.3.0",
                draft: false,
                prerelease: false,
                assets: [
                    GitHubReleaseAsset(
                        name: "BalanceBar-1.3.0.dmg",
                        browserDownloadURL: URL(string: "https://github.com/huanmeng06/BalanceBar/releases/download/v1.3.0/BalanceBar-1.3.0.dmg"),
                        size: nil,
                        digest: nil
                    )
                ]
            )
        ]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard case .available = service.state else {
            XCTFail("the startup check should publish the available state")
            return
        }

        let availableRequestCount = fetcher.requestCount
        appDelegate.backgroundUpdateTimerForTesting?.fire()
        XCTAssertEqual(
            fetcher.requestCount,
            availableRequestCount,
            "the low-frequency check must not clear an already available badge"
        )
    }

    @MainActor
    func testStatusItemDisplayModeHidesInPlaceAndRestoresWhenCodexRuns() {
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
        let makeSettings: (MenuBarIconDisplayMode) -> StatusItemController.MenuBarSettings = { mode in
            StatusItemController.MenuBarSettings(
                showIcon: true,
                showAmount: true,
                showReset: true,
                horizontalPadding: 6,
                keepMenuOpenAfterRefresh: true,
                iconDisplayMode: mode
            )
        }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: makeSettings(.onlyWhileRunning)
        )
        let installCount = controller.statusItemInstallCount

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(controller.isVisible, "the first idle sample remains visible")
        RunLoop.main.run(
            until: Date().addingTimeInterval(
                MenuBarIconDisplayStateMachine.idleConfirmationInterval
                + 0.05
            )
        )
        controller.update(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: makeSettings(.onlyWhileRunning)
        )
        XCTAssertTrue(
            controller.isVisible,
            "a layout refresh must not count as a second idle activity sample"
        )
        controller.observeCodexTaskSample(
            false,
            at: Date().addingTimeInterval(MenuBarIconDisplayDelay.tenSeconds.duration + 1)
        )
        XCTAssertFalse(
            controller.isVisible,
            "stable idle hides the existing status item after its grace period"
        )
        XCTAssertEqual(controller.statusItemInstallCount, installCount)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(controller.isVisible, "Codex activity shows the existing status item immediately")
        XCTAssertEqual(controller.statusItemInstallCount, installCount)
        controller.teardown()
    }

    @MainActor
    func testLiveStatusItemUsesSelectedOfficialQuotaWindowForCompactPresentation() throws {
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
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour",
            daysText: "5 hours",
            reset: "1h0m",
            durationSeconds: 18_000
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day",
            daysText: "7 days",
            reset: "1h30m",
            durationSeconds: 604_800
        )
        let snapshot = Snapshot.official(
            "OpenAI",
            sevenDay.remaining,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [sevenDay, fiveHour]
        )
        let fiveHourSettings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 10,
            keepMenuOpenAfterRefresh: true,
            quotaWindowPreference: .fiveHour
        )
        controller.start(
            snapshot: snapshot,
            refreshDate: nil,
            menuInput: input,
            settings: fiveHourSettings
        )
        XCTAssertEqual(controller.menuBarPrimaryTextForTesting, "80%")
        XCTAssertEqual(controller.menuBarSecondaryTextForTesting, "1h0m")

        let sevenDaySettings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 10,
            keepMenuOpenAfterRefresh: true,
            quotaWindowPreference: .sevenDay
        )
        controller.update(
            snapshot: snapshot,
            refreshDate: nil,
            menuInput: input,
            settings: sevenDaySettings
        )
        XCTAssertEqual(controller.menuBarPrimaryTextForTesting, "45%")
        XCTAssertEqual(controller.menuBarSecondaryTextForTesting, "1h30m")

        let onlyFiveHour = Snapshot.official(
            "OpenAI",
            fiveHour.remaining,
            fiveHour.label,
            fiveHour.reset,
            date,
            windows: [fiveHour]
        )
        controller.update(
            snapshot: onlyFiveHour,
            refreshDate: nil,
            menuInput: input,
            settings: sevenDaySettings
        )
        XCTAssertEqual(controller.menuBarPrimaryTextForTesting, "!")
        XCTAssertEqual(controller.menuBarSecondaryTextForTesting, "")
        controller.teardown()
    }

    @MainActor
    func testLiveStatusItemAutoSwitchesWholePrimaryToLunaReserveAndSelectsResetSource() {
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
            openAIAccount: nil,
            statusLinks: [],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showOpenCodexMenu: true,
            showStatusMenu: true
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 18_000
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 604_800
        )
        let snapshot = Snapshot.official(
            "OpenAI",
            sevenDay.remaining,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [fiveHour, sevenDay],
            lunaReserve: LunaReserveQuota(status: .available, remaining: 61, reset: "2h")
        )
        let exhaustedSevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 0,
            label: sevenDay.label,
            daysText: sevenDay.daysText,
            reset: sevenDay.reset,
            durationSeconds: sevenDay.durationSeconds
        )
        let exhaustedSnapshot = Snapshot.official(
            "OpenAI",
            exhaustedSevenDay.remaining,
            exhaustedSevenDay.label,
            exhaustedSevenDay.reset,
            date,
            windows: [fiveHour, exhaustedSevenDay],
            lunaReserve: LunaReserveQuota(status: .available, remaining: 61, reset: "2h")
        )
        func settings(
            autoSwitch: Bool,
            resetTimeMode: LunaReserveResetTimeMode
        ) -> StatusItemController.MenuBarSettings {
            StatusItemController.MenuBarSettings(
                showIcon: true,
                showAmount: true,
                showReset: true,
                horizontalPadding: 10,
                keepMenuOpenAfterRefresh: true,
                quotaWindowPreference: .sevenDay,
                quotaResetDisplayMode: .remaining,
                autoSwitchLunaReserve: autoSwitch,
                lunaReserveResetTimeMode: resetTimeMode
            )
        }

        controller.start(
            snapshot: snapshot,
            refreshDate: nil,
            menuInput: input,
            settings: settings(autoSwitch: true, resetTimeMode: .lunaReserve)
        )
        XCTAssertEqual(controller.menuBarPrimaryTextForTesting, "45%")
        XCTAssertEqual(controller.menuBarSecondaryTextForTesting, "7d")

        controller.update(
            snapshot: exhaustedSnapshot,
            refreshDate: nil,
            menuInput: input,
            settings: settings(autoSwitch: true, resetTimeMode: .originalQuota)
        )
        XCTAssertEqual(controller.menuBarPrimaryTextForTesting, "61% 🌙")
        XCTAssertEqual(controller.menuBarSecondaryTextForTesting, "7d")

        controller.update(
            snapshot: snapshot,
            refreshDate: nil,
            menuInput: input,
            settings: settings(autoSwitch: false, resetTimeMode: .lunaReserve)
        )
        XCTAssertEqual(controller.menuBarPrimaryTextForTesting, "45%")
        XCTAssertEqual(controller.menuBarSecondaryTextForTesting, "7d")
    }

    @MainActor
    func testLiveStatusItemUsesQuotaResetDisplayModeForCompactPresentation() throws {
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
        let now = Date()
        let resetAt = now.addingTimeInterval(3_600)
        let window = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour",
            daysText: "5 hours",
            reset: "1h0m",
            durationSeconds: 18_000,
            resetAt: resetAt
        )
        let snapshot = Snapshot.official(
            "OpenAI",
            window.remaining,
            window.label,
            window.reset,
            now,
            windows: [window]
        )
        func settings(mode: OfficialQuotaResetDisplayMode) -> StatusItemController.MenuBarSettings {
            StatusItemController.MenuBarSettings(
                showIcon: true,
                showAmount: true,
                showReset: true,
                horizontalPadding: 10,
                keepMenuOpenAfterRefresh: true,
                quotaWindowPreference: .fiveHour,
                quotaResetDisplayMode: mode
            )
        }

        controller.start(
            snapshot: snapshot,
            refreshDate: nil,
            menuInput: input,
            settings: settings(mode: .remaining)
        )
        XCTAssertEqual(controller.menuBarSecondaryTextForTesting, "1h0m")

        controller.update(
            snapshot: snapshot,
            refreshDate: nil,
            menuInput: input,
            settings: settings(mode: .resetAt)
        )
        let targetText = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(for: resetAt, relativeTo: Date())
        )
        XCTAssertEqual(controller.menuBarSecondaryTextForTesting, targetText)
        XCTAssertNotEqual(controller.menuBarSecondaryTextForTesting, window.reset)

        controller.update(
            snapshot: snapshot,
            refreshDate: nil,
            menuInput: input,
            settings: settings(mode: .both)
        )
        XCTAssertEqual(
            controller.menuBarSecondaryTextForTesting,
            tr(.keySnapshotValueValue, arguments: [window.reset!, targetText])
        )
        controller.teardown()
    }

    @MainActor
    func testLiveStatusItemOfficialAmountOnlyKeepsPrimaryInkAnchored() throws {
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
        let scenarios: [(Snapshot, Bool)] = [
            (
                Snapshot.official(
                    "OpenAI",
                    48,
                    "7-day",
                    nil,
                    Date(timeIntervalSince1970: 1)
                ),
                false
            ),
            (
                Snapshot.balance(
                    "Provider",
                    123456.78,
                    "USD",
                    nil,
                    Date(timeIntervalSince1970: 1)
                ),
                true
            ),
            (
                Snapshot.balance(
                    "Provider",
                    0.10,
                    "USD",
                    nil,
                    Date(timeIntervalSince1970: 1)
                ),
                true
            )
        ]
        defer { controller.teardown() }

        for (snapshot, isBalance) in scenarios {
            for showIcon in [true, false] {
            var observations: [(MenuBarFontSizePreset, NSRect, NSRect)] = []
            var previousLength: CGFloat?
            for preset in MenuBarFontSizePreset.allCases {
                let settings = StatusItemController.MenuBarSettings(
                    showIcon: showIcon,
                    showAmount: true,
                    showReset: false,
                    horizontalPadding: 10,
                    keepMenuOpenAfterRefresh: true,
                    widthAdjustment: 0,
                    fontSize: CGFloat(preset.primarySize)
                )
                if controller.statusItemInstallCount == 0 {
                    controller.start(
                        snapshot: snapshot,
                        refreshDate: nil,
                        menuInput: input,
                        settings: settings
                    )
                } else {
                    controller.update(
                        snapshot: snapshot,
                        refreshDate: nil,
                        menuInput: input,
                        settings: settings
                    )
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))

                let ink = try XCTUnwrap(controller.menuBarPrimaryInkBoundsForTesting)
                let button = try XCTUnwrap(controller.menuBarButtonBoundsForTesting)
                observations.append((preset, ink, button))
                let expectedLength = MenuBarLayout.singleLineStatusItemLength(
                    primaryText: snapshot.menuBarPrimary,
                    showIcon: showIcon,
                    isBalance: isBalance,
                    horizontalPadding: 10
                )
                XCTAssertEqual(
                    controller.statusItemLengthForTesting ?? .nan,
                    expectedLength,
                    accuracy: 0.5,
                    "single-line reserve was not applied"
                )
                if let previousLength {
                    XCTAssertEqual(
                        controller.statusItemLengthForTesting ?? .nan,
                        previousLength,
                        accuracy: 0.5,
                        "official amount-only width changed at \(preset), icon=\(showIcon)"
                    )
                }
                previousLength = controller.statusItemLengthForTesting
                let automaticYOffset = MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                    fontSize: settings.fontSize
                )
                XCTAssertEqual(
                    ink.midY,
                    button.midY - automaticYOffset,
                    accuracy: 0.5,
                    "primary ink has an unexpected vertical baseline, icon=\(showIcon), preset=\(preset)"
                )
                if showIcon {
                    let icon = try XCTUnwrap(controller.menuBarIconFrameForTesting)
                    XCTAssertEqual(
                        icon.midY,
                        button.midY,
                        accuracy: 0.5,
                        "icon alignment changed, preset=\(preset)"
                    )
                }
            }

            let primaryCenters = observations.map { $0.1.midX }
            XCTAssertLessThanOrEqual(
                (primaryCenters.max() ?? 0) - (primaryCenters.min() ?? 0),
                0.5,
                "official primary ink X drifted with icon=\(showIcon)"
            )
            let large = try XCTUnwrap(observations.first { $0.0 == .large }?.1)
            let small = try XCTUnwrap(observations.first { $0.0 == .small }?.1)
            XCTAssertGreaterThanOrEqual(large.width, small.width)
            XCTAssertGreaterThan(
                abs(large.maxX - large.midX),
                abs(small.maxX - small.midX) - 0.5,
                "shrinking the font must move both edges around primary center"
            )

            let baseLength = try XCTUnwrap(controller.statusItemLengthForTesting)
            controller.updateWidthAdjustment(10)
            XCTAssertEqual(
                controller.statusItemLengthForTesting ?? .nan,
                baseLength + 10,
                accuracy: 0.5
            )
            controller.updateWidthAdjustment(20)
            XCTAssertEqual(
                controller.statusItemLengthForTesting ?? .nan,
                baseLength + 20,
                accuracy: 0.5
            )
            controller.updateWidthAdjustment(0)

            let adjustedSettings = StatusItemController.MenuBarSettings(
                showIcon: showIcon,
                showAmount: true,
                showReset: false,
                horizontalPadding: 10,
                keepMenuOpenAfterRefresh: true,
                amountOffsetY: 0.75,
                widthAdjustment: 0,
                fontSize: CGFloat(MenuBarFontSizePreset.large.primarySize)
            )
            controller.update(
                snapshot: snapshot,
                refreshDate: nil,
                menuInput: input,
                settings: adjustedSettings
            )
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let adjustedInk = try XCTUnwrap(controller.menuBarPrimaryInkBoundsForTesting)
            let adjustedButton = try XCTUnwrap(controller.menuBarButtonBoundsForTesting)
                XCTAssertEqual(
                    adjustedInk.midY,
                    adjustedButton.midY
                        - MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                            fontSize: adjustedSettings.fontSize
                        )
                        - 0.75,
                    accuracy: 0.5,
                    "user amount Y adjustment must remain visible"
                )
            }
        }
    }

    func testDatabaseWatcherStartAndStopAreIdempotent() {
        let watcher = CCSwitchDatabaseWatcher(
            databaseURL: URL(fileURLWithPath: "/nonexistent/issue-30-watcher.db"),
            onChange: {}
        )
        watcher.start()
        watcher.start()
        XCTAssertEqual(watcher.startCount, 1)
        watcher.stop()
        watcher.stop()
    }

    @MainActor
    func testActivityCoordinatorInstallsOneTimerAndObserverPerLifecycle() {
        let coordinator = ActivityCoordinator(
            actions: ActivityCoordinatorActions(
                activeClient: { .codex },
                claudeProcessAvailable: { false },
                setClaudeProcessAvailable: { _ in },
                setActiveClient: { _ in },
                setCodexTaskRunning: { _ in },
                setClaudeTaskRunning: { _ in }
            )
        )
        coordinator.start(interval: 60)
        coordinator.start(interval: 60)
        XCTAssertEqual(coordinator.startCount, 1)
        coordinator.stop()
        coordinator.stop()
    }

    func testActivityLifecycleRequiresDistinctSamplesAndHalfSecondActivationHold() {
        var machine = ActivityLifecycleStateMachine()
        let start = Date(timeIntervalSince1970: 5_000)

        XCTAssertFalse(machine.observe(.active, at: start))
        XCTAssertFalse(
            machine.observe(.active, at: start),
            "a duplicate sample at the same instant must not count as an independent confirmation"
        )
        XCTAssertFalse(
            machine.observe(.active, at: start.addingTimeInterval(0.25)),
            "two samples are not enough before the minimum activation hold elapses"
        )
        XCTAssertTrue(
            machine.observe(.active, at: start.addingTimeInterval(0.5)),
            "a stable active signal should commit after the 0.5 second confirmation window"
        )
    }

    func testActivityLifecycleDoesNotJoinSeparatedActivationSamples() {
        var machine = ActivityLifecycleStateMachine()
        let start = Date(timeIntervalSince1970: 6_000)

        XCTAssertFalse(machine.observe(.active, at: start))
        XCTAssertFalse(
            machine.observe(.active, at: start.addingTimeInterval(3)),
            "a long sample gap must discard the stale activation candidate"
        )
        XCTAssertFalse(machine.observe(.ambiguousIdle, at: start.addingTimeInterval(3.25)))
        XCTAssertFalse(machine.observe(.active, at: start.addingTimeInterval(3.5)))
        XCTAssertTrue(machine.observe(.active, at: start.addingTimeInterval(4)))
    }

    func testActivityLifecycleKeepsShortAmbiguousIdlePauseStable() {
        var machine = ActivityLifecycleStateMachine()
        let start = Date(timeIntervalSince1970: 7_000)

        XCTAssertFalse(machine.observe(.active, at: start))
        XCTAssertTrue(machine.observe(.active, at: start.addingTimeInterval(0.5)))
        XCTAssertTrue(machine.observe(.ambiguousIdle, at: start.addingTimeInterval(1)))
        XCTAssertTrue(
            machine.observe(.active, at: start.addingTimeInterval(4)),
            "activity during the grace window must cancel the pending idle"
        )
        XCTAssertTrue(machine.isRunning)
    }

    func testActivityLifecycleCommitsAmbiguousIdleOnlyAfterTenSeconds() {
        var machine = ActivityLifecycleStateMachine()
        let start = Date(timeIntervalSince1970: 8_000)

        XCTAssertFalse(machine.observe(.active, at: start))
        XCTAssertTrue(machine.observe(.active, at: start.addingTimeInterval(0.5)))
        XCTAssertTrue(machine.observe(.ambiguousIdle, at: start.addingTimeInterval(1)))
        XCTAssertTrue(
            machine.observe(.ambiguousIdle, at: start.addingTimeInterval(10.99)),
            "ambiguous idle must remain provisional before ten seconds"
        )
        XCTAssertFalse(
            machine.observe(.ambiguousIdle, at: start.addingTimeInterval(11)),
            "ten seconds of ambiguous idle should commit the idle state"
        )
    }

    func testActivityLifecycleHardTerminalBypassesIdleGrace() {
        var machine = ActivityLifecycleStateMachine()
        let start = Date(timeIntervalSince1970: 9_000)

        XCTAssertFalse(machine.observe(.active, at: start))
        XCTAssertTrue(machine.observe(.active, at: start.addingTimeInterval(0.5)))
        XCTAssertTrue(machine.observe(.ambiguousIdle, at: start.addingTimeInterval(1)))
        XCTAssertFalse(
            machine.observe(.hardTerminal, at: start.addingTimeInterval(1.1)),
            "explicit completion/failure/cancellation must stop immediately"
        )
    }

    func testActivityLifecycleTreatsContextCompactionAsActiveAndSupportsIndependentClients() {
        var codex = ActivityLifecycleStateMachine()
        var claude = ActivityLifecycleStateMachine()
        let start = Date(timeIntervalSince1970: 10_000)

        XCTAssertFalse(codex.observe(.active, at: start))
        XCTAssertFalse(claude.observe(.active, at: start))
        XCTAssertTrue(codex.observe(.active, at: start.addingTimeInterval(0.5)))
        XCTAssertTrue(claude.observe(.active, at: start.addingTimeInterval(0.5)))

        XCTAssertTrue(codex.observe(.contextCompaction, at: start.addingTimeInterval(20)))
        XCTAssertTrue(
            claude.observe(.ambiguousIdle, at: start.addingTimeInterval(1)),
            "a Codex compaction/idle candidate must not alter Claude's committed state"
        )
        XCTAssertFalse(
            claude.observe(.hardTerminal, at: start.addingTimeInterval(1.1))
        )
        XCTAssertTrue(
            codex.observe(.ambiguousIdle, at: start.addingTimeInterval(21)),
            "Claude's terminal must not alter Codex's committed state"
        )
    }

    func testActivityLifecycleResetClearsPendingAndCommittedState() {
        var machine = ActivityLifecycleStateMachine()
        let start = Date(timeIntervalSince1970: 11_000)

        XCTAssertFalse(machine.observe(.active, at: start))
        XCTAssertFalse(machine.reset())
        XCTAssertFalse(machine.observe(.active, at: start.addingTimeInterval(0.5)))
        XCTAssertTrue(machine.observe(.active, at: start.addingTimeInterval(1)))
        XCTAssertTrue(machine.reset())
        XCTAssertFalse(machine.isRunning)
        XCTAssertFalse(machine.observe(.ambiguousIdle, at: start.addingTimeInterval(11)))
    }

    private func balanceBarSource(file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: String(describing: file))
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot
            .appendingPathComponent("work/balance-bar/BalanceBar.swift"), encoding: .utf8)
    }

    private func makeStatusMenuInput(
        showsAvailableUpdateBadge: Bool
    ) -> StatusItemController.MenuInput {
        StatusItemController.MenuInput(
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
            showStatusMenu: true,
            showsAvailableUpdateBadge: showsAvailableUpdateBadge
        )
    }

    private func compositionSources(file: StaticString = #filePath) throws -> [String: String] {
        let testFile = URL(fileURLWithPath: String(describing: file))
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "DashboardCompositionController.swift": "work/balance-bar/Sources/UI/Dashboard/DashboardCompositionController.swift",
            "ProviderRefreshCoordinator.swift": "work/balance-bar/Sources/Services/ProviderRefreshCoordinator.swift",
            "OpenCodexRefreshCoordinator.swift": "work/balance-bar/Sources/Services/OpenCodexRefreshCoordinator.swift",
            "ActivityCoordinator.swift": "work/balance-bar/Sources/Monitoring/ActivityCoordinator.swift",
            "CCSwitchDatabaseWatcher.swift": "work/balance-bar/Sources/Services/CCSwitchDatabaseWatcher.swift",
            "ProviderSwitchCoordinator.swift": "work/balance-bar/Sources/Services/ProviderSwitchCoordinator.swift"
        ]
        return try Dictionary(uniqueKeysWithValues: files.map { name, path in
            (name, try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8))
        })
    }
}

private final class StartupUpdateReleaseFetcher: GitHubReleaseFetching {
    private(set) var requestCount = 0
    private var pendingCompletion: ((Result<[GitHubRelease], GitHubReleaseClientError>) -> Void)?

    func fetchReleases(
        completion: @escaping (Result<[GitHubRelease], GitHubReleaseClientError>) -> Void
    ) {
        requestCount += 1
        pendingCompletion = completion
    }

    func resolve(_ result: Result<[GitHubRelease], GitHubReleaseClientError>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }
}

@MainActor
final class ApplicationMenuConfigurationTests: XCTestCase {
    func testWindowMenuRestoresStandardCommandsAndResponderRouting() throws {
        let configuration = ApplicationMenuConfiguration.make()
        let windowMenu = configuration.windowMenu

        let close = try XCTUnwrap(item(in: windowMenu, action: #selector(NSWindow.performClose(_:))))
        XCTAssertEqual(close.keyEquivalent, "w")
        XCTAssertEqual(close.keyEquivalentModifierMask, [.command])
        XCTAssertNil(close.target)

        let minimize = try XCTUnwrap(item(in: windowMenu, action: #selector(NSWindow.performMiniaturize(_:))))
        XCTAssertEqual(minimize.keyEquivalent, "m")
        XCTAssertEqual(minimize.keyEquivalentModifierMask, [.command])
        XCTAssertNil(minimize.target)

        let zoom = try XCTUnwrap(item(in: windowMenu, action: #selector(NSWindow.performZoom(_:))))
        XCTAssertTrue(zoom.keyEquivalent.isEmpty)
        XCTAssertNil(zoom.target)

        let arrange = try XCTUnwrap(item(in: windowMenu, action: #selector(NSApplication.arrangeInFront(_:))))
        XCTAssertTrue(arrange.keyEquivalent.isEmpty)
        XCTAssertNil(arrange.target)
        XCTAssertTrue(configuration.mainMenu.items.contains { $0.submenu === windowMenu })
    }

    func testApplicationAndEditMenusPreserveDefaultShortcutCommands() throws {
        let configuration = ApplicationMenuConfiguration.make()
        let applicationMenu = try XCTUnwrap(configuration.mainMenu.items.first?.submenu)
        let editMenu = try XCTUnwrap(configuration.mainMenu.items.dropFirst().first?.submenu)

        let hide = try XCTUnwrap(item(in: applicationMenu, action: #selector(NSApplication.hide(_:))))
        XCTAssertEqual(hide.keyEquivalent, "h")
        XCTAssertEqual(hide.keyEquivalentModifierMask, [.command])

        let hideOthers = try XCTUnwrap(item(in: applicationMenu, action: #selector(NSApplication.hideOtherApplications(_:))))
        XCTAssertEqual(hideOthers.keyEquivalent, "h")
        XCTAssertEqual(hideOthers.keyEquivalentModifierMask, [.command, .option])

        let quit = try XCTUnwrap(item(in: applicationMenu, action: #selector(NSApplication.terminate(_:))))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(quit.target === NSApp)

        let expectedEditCommands: [(Selector, String, NSEvent.ModifierFlags)] = [
            (#selector(UndoManager.undo), "z", [.command]),
            (#selector(UndoManager.redo), "z", [.command, .shift]),
            (#selector(NSText.cut(_:)), "x", [.command]),
            (#selector(NSText.copy(_:)), "c", [.command]),
            (#selector(NSText.paste(_:)), "v", [.command]),
            (#selector(NSText.selectAll(_:)), "a", [.command])
        ]
        for (action, keyEquivalent, modifiers) in expectedEditCommands {
            let item = try XCTUnwrap(item(in: editMenu, action: action))
            XCTAssertEqual(item.keyEquivalent, keyEquivalent)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
        }
    }

    func testDashboardWindowKeepsMiniaturizableStyleForWindowCommandRouting() throws {
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
        let minimize = try XCTUnwrap(
            item(in: ApplicationMenuConfiguration.make().windowMenu, action: #selector(NSWindow.performMiniaturize(_:)))
        )

        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.responds(to: try XCTUnwrap(minimize.action)))
        XCTAssertNil(minimize.target)
    }

    private func item(in menu: NSMenu, action: Selector) -> NSMenuItem? {
        menu.items.first { $0.action == action }
    }
}
