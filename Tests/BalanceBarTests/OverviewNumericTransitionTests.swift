import AppKit
import XCTest
@testable import BalanceBar

final class OverviewNumericTransitionTests: XCTestCase {
    func testSameIdentityPercentTransitionAnimatesAndUnchangedValueDoesNot() {
        let previous = percentSample(identity: fiveHour, value: 84)
        let current = percentSample(identity: fiveHour, value: 71)

        let changed = OverviewNumericTransition.plan(
            previous: previous,
            current: current,
            reduceMotion: false
        )
        XCTAssertTrue(changed.animates)
        XCTAssertEqual(changed.startText, "84%")
        XCTAssertEqual(changed.endText, "71%")
        XCTAssertEqual(changed.startProgress, 84)
        XCTAssertEqual(changed.toProgress, 71)

        let unchanged = OverviewNumericTransition.plan(
            previous: previous,
            current: previous,
            reduceMotion: false
        )
        XCTAssertFalse(unchanged.animates)
        XCTAssertEqual(unchanged.startText, "84%")
        XCTAssertEqual(unchanged.endText, "84%")
    }

    func testMissingCacheIdentityChangeAndFormatMismatchDoNotAnimate() {
        let percent = percentSample(identity: fiveHour, value: 84)
        let otherWindow = percentSample(identity: sevenDay, value: 71)
        let balance = OverviewNumericSample(
            identity: .thirdPartyBalance(provider: "Provider", unit: "CNY"),
            format: .currency(unit: "CNY"),
            value: 1.5,
            progressPercentage: 40
        )

        let firstOpen = OverviewNumericTransition.plan(
            previous: nil,
            current: percent,
            reduceMotion: false
        )
        XCTAssertFalse(firstOpen.animates)
        XCTAssertEqual(firstOpen.startText, "84%")
        XCTAssertEqual(firstOpen.endText, "84%")

        let identityChanged = OverviewNumericTransition.plan(
            previous: percent,
            current: otherWindow,
            reduceMotion: false
        )
        XCTAssertFalse(identityChanged.animates)
        XCTAssertEqual(identityChanged.startText, "71%")

        let formatChanged = OverviewNumericTransition.plan(
            previous: percent,
            current: balance,
            reduceMotion: false
        )
        XCTAssertFalse(formatChanged.animates)
        XCTAssertEqual(formatChanged.startText, "¥1.50")
        XCTAssertEqual(formatChanged.endText, "¥1.50")
    }

    func testReduceMotionUsesCurrentValueImmediately() {
        let plan = OverviewNumericTransition.plan(
            previous: percentSample(identity: fiveHour, value: 84),
            current: percentSample(identity: fiveHour, value: 71),
            reduceMotion: true
        )
        XCTAssertFalse(plan.animates)
        XCTAssertEqual(plan.startText, "71%")
        XCTAssertEqual(plan.endText, "71%")
        XCTAssertEqual(plan.startProgress, 71)
    }

    func testPercentAndBalanceFormattingMatchExistingDisplayRules() {
        XCTAssertEqual(OverviewNumericFormat.integerPercent.displayText(for: 84.9), "84%")
        XCTAssertEqual(OverviewNumericFormat.integerPercent.displayText(for: 71), "71%")
        XCTAssertEqual(
            OverviewNumericFormat.currency(unit: "CNY").displayText(for: 1.5),
            StatusItemController.formatBalanceSummary(1.5, unit: "CNY")
        )
        XCTAssertEqual(
            OverviewNumericFormat.currency(unit: "USD").displayText(for: 1.7),
            StatusItemController.formatBalanceSummary(1.7, unit: "USD")
        )
        XCTAssertEqual(OverviewNumericFormat.integerCount.displayText(for: 2), "2")
    }

    func testFiveHourAndSevenDayCachesDoNotOverwriteEachOther() {
        let fiveHourSeen = percentSample(identity: fiveHour, value: 84)
        let sevenDaySeen = percentSample(identity: sevenDay, value: 45)
        let cache = OverviewNumericTransition.commitSeenValues([fiveHourSeen, sevenDaySeen])

        XCTAssertEqual(cache[fiveHour]?.value, 84)
        XCTAssertEqual(cache[sevenDay]?.value, 45)

        let fiveHourPlan = OverviewNumericTransition.plan(
            previous: cache[fiveHour],
            current: percentSample(identity: fiveHour, value: 71),
            reduceMotion: false
        )
        let sevenDayPlan = OverviewNumericTransition.plan(
            previous: cache[sevenDay],
            current: percentSample(identity: sevenDay, value: 45),
            reduceMotion: false
        )
        XCTAssertTrue(fiveHourPlan.animates)
        XCTAssertEqual(fiveHourPlan.startText, "84%")
        XCTAssertFalse(sevenDayPlan.animates)
        XCTAssertEqual(sevenDayPlan.startText, "45%")
    }

    func testSamplesKeepOfficialWindowsAndBalanceOnSeparateIdentities() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let official = Snapshot.official(
            "OpenAI Official",
            45,
            "7-day",
            "1h",
            date,
            windows: [
                OfficialQuotaWindow(
                    kind: .fiveHour,
                    remaining: 84,
                    label: "5 hour",
                    daysText: "5h",
                    reset: "1h",
                    durationSeconds: 18_000
                ),
                OfficialQuotaWindow(
                    kind: .sevenDay,
                    remaining: 45,
                    label: "7 day",
                    daysText: "7d",
                    reset: "2d",
                    durationSeconds: 604_800
                )
            ]
        )
        let officialSamples = OverviewNumericPresentation.samples(
            snapshot: official,
            lunaReserveDisplayMode: .disabled,
            hideExhaustedQuota: false,
            showBankedReset: false
        )
        XCTAssertEqual(
            officialSamples.map(\.identity),
            [fiveHour, sevenDay]
        )

        let balance = Snapshot.balance("Provider", 1.7, "CNY", nil, date, progressPercentage: 40)
        let balanceSamples = OverviewNumericPresentation.samples(
            snapshot: balance,
            lunaReserveDisplayMode: .disabled,
            hideExhaustedQuota: false,
            showBankedReset: false
        )
        XCTAssertEqual(balanceSamples.count, 1)
        XCTAssertEqual(
            balanceSamples[0].identity,
            .thirdPartyBalance(provider: "Provider", unit: "CNY")
        )
        XCTAssertEqual(balanceSamples[0].displayText, "¥1.70")
    }

    private var fiveHour: OverviewNumericIdentity {
        .officialWindow(provider: "OpenAI Official", kind: .fiveHour)
    }

    private var sevenDay: OverviewNumericIdentity {
        .officialWindow(provider: "OpenAI Official", kind: .sevenDay)
    }

    private func percentSample(
        identity: OverviewNumericIdentity,
        value: Double
    ) -> OverviewNumericSample {
        OverviewNumericSample(
            identity: identity,
            format: .integerPercent,
            value: value,
            progressPercentage: value
        )
    }
}

@MainActor
final class OverviewNumericPresentationControllerTests: XCTestCase {
    func testFirstOpenShowsCurrentValuesAndLaterOpenStartsFromLastSeen() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.overviewNumericReduceMotionForTesting = false

        controller.start(
            snapshot: officialSnapshot(fiveHour: 84, sevenDay: 45),
            refreshDate: Date(),
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        let firstOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(amountTexts(in: firstOverview), ["84%", "45%"])
        XCTAssertEqual(progressValues(in: firstOverview), [84, 45])

        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.menuDidClose(controller.statusMenuForTesting)
        XCTAssertEqual(
            controller.lastSeenOverviewNumericsForTesting[fiveHour]?.displayText,
            "84%"
        )

        controller.update(
            snapshot: officialSnapshot(fiveHour: 71, sevenDay: 45),
            refreshDate: Date(),
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        let secondOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(amountTexts(in: secondOverview), ["84%", "45%"])
        XCTAssertEqual(progressValues(in: secondOverview), [84, 45])
        XCTAssertNotEqual(controller.menuBarPrimaryTextForTesting, "84%")
    }

    func testReduceMotionAndProviderSwitchShowCurrentValueImmediately() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.overviewNumericReduceMotionForTesting = false
        let date = Date()

        controller.start(
            snapshot: officialSnapshot(fiveHour: 84, sevenDay: 45),
            refreshDate: date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.menuDidClose(controller.statusMenuForTesting)

        controller.overviewNumericReduceMotionForTesting = true
        controller.update(
            snapshot: officialSnapshot(fiveHour: 71, sevenDay: 45),
            refreshDate: date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        let reduced = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(amountTexts(in: reduced), ["71%", "45%"])
        XCTAssertEqual(progressValues(in: reduced), [71, 45])

        controller.overviewNumericReduceMotionForTesting = false
        controller.update(
            snapshot: Snapshot.balance("Provider", 1.5, "CNY", nil, date, progressPercentage: 30),
            refreshDate: date,
            menuInput: makeMenuInput(activeClient: .grok),
            settings: makeSettings()
        )
        let switched = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(amountTexts(in: switched), ["¥1.50"])
        XCTAssertEqual(progressValues(in: switched), [30])
    }

    func testProgressBarHiddenStillRollsNumbersAndLeavesNoBar() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.overviewNumericReduceMotionForTesting = false
        let settingsWithoutBar = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true,
            showQuotaProgressBar: false
        )

        controller.start(
            snapshot: officialSnapshot(fiveHour: 84, sevenDay: 45),
            refreshDate: Date(),
            menuInput: makeMenuInput(),
            settings: settingsWithoutBar
        )
        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.menuDidClose(controller.statusMenuForTesting)
        controller.update(
            snapshot: officialSnapshot(fiveHour: 71, sevenDay: 45),
            refreshDate: Date(),
            menuInput: makeMenuInput(),
            settings: settingsWithoutBar
        )
        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(amountTexts(in: overview), ["84%", "45%"])
        XCTAssertTrue(progressValues(in: overview).isEmpty)
    }

    private var fiveHour: OverviewNumericIdentity {
        .officialWindow(provider: "OpenAI Official", kind: .fiveHour)
    }

    private func amountTexts(in view: NSView) -> [String] {
        descendantViews(of: view, as: OverviewNumericTextView.self).map(\.textField.stringValue)
    }

    private func progressValues(in view: NSView) -> [Double] {
        descendantViews(of: view, as: QuotaProgressView.self).map(\.percentage)
    }

    private func descendantViews<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var matches: [T] = []
        if let match = view as? T {
            matches.append(match)
        }
        for child in view.subviews {
            matches.append(contentsOf: descendantViews(of: child, as: type))
        }
        return matches
    }

    private func officialSnapshot(fiveHour: Double, sevenDay: Double) -> Snapshot {
        Snapshot.official(
            "OpenAI Official",
            sevenDay,
            "7-day",
            "1h",
            Date(timeIntervalSince1970: 1_700_000_000),
            windows: [
                OfficialQuotaWindow(
                    kind: .fiveHour,
                    remaining: fiveHour,
                    label: "5 hour",
                    daysText: "5h",
                    reset: "1h",
                    durationSeconds: 18_000
                ),
                OfficialQuotaWindow(
                    kind: .sevenDay,
                    remaining: sevenDay,
                    label: "7 day",
                    daysText: "7d",
                    reset: "2d",
                    durationSeconds: 604_800
                )
            ]
        )
    }

    private func makeController() -> StatusItemController {
        StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
    }

    private func makeMenuInput(
        activeClient: AssistantClient = .codex
    ) -> StatusItemController.MenuInput {
        StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: activeClient,
            openAIAccount: nil,
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false
        )
    }

    private func makeSettings() -> StatusItemController.MenuBarSettings {
        StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
    }
}
