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
            OverviewNumericFormat.currency(unit: "CNY").displayText(for: 1.70),
            StatusItemController.formatBalanceSummary(1.70, unit: "CNY")
        )
        XCTAssertEqual(OverviewNumericFormat.currency(unit: "CNY").displayText(for: 1.70), "¥1.70")
        XCTAssertEqual(OverviewNumericFormat.currency(unit: "CNY").displayText(for: 1.69), "¥1.69")
        XCTAssertEqual(OverviewNumericFormat.currency(unit: "CNY").displayText(for: 1.50), "¥1.50")
        XCTAssertEqual(
            OverviewNumericFormat.currency(unit: "CNY").displayText(for: 1.5),
            StatusItemController.formatBalanceSummary(1.5, unit: "CNY")
        )
        XCTAssertEqual(
            OverviewNumericFormat.currency(unit: "USD").displayText(for: 1.7),
            StatusItemController.formatBalanceSummary(1.7, unit: "USD")
        )
        XCTAssertEqual(OverviewNumericFormat.currency(unit: "USD").displayText(for: 1.70), "$1.70")
        XCTAssertEqual(OverviewNumericFormat.integerCount.displayText(for: 2), "2")
        XCTAssertEqual(
            OverviewNumericFormat.remainingSeconds.displayText(for: 5_025),
            "1h23m45s"
        )
        XCTAssertEqual(
            OverviewNumericFormat.remainingSeconds.displayText(for: 723),
            "12m03s"
        )
        XCTAssertEqual(OverviewNumericFormat.remainingSeconds.displayText(for: 45), "45s")
        XCTAssertEqual(OverviewNumericFormat.remainingSeconds.displayText(for: 0), "0s")
        XCTAssertTrue(OverviewNumericFormat.remainingSeconds.displayParts.remainingTime)

        let cnyParts = OverviewNumericFormat.currency(unit: "CNY").displayParts
        XCTAssertEqual(cnyParts.prefix, "¥")
        XCTAssertEqual(cnyParts.suffix, "")
        XCTAssertEqual(cnyParts.fractionLength, 2)
        XCTAssertEqual(
            cnyParts.prefix
                + 1.70.formatted(.number.precision(.fractionLength(2)))
                + cnyParts.suffix,
            StatusItemController.formatBalanceSummary(1.70, unit: "CNY")
        )
        XCTAssertEqual(OverviewNumericFormat.currency(unit: "USD").displayParts.prefix, "$")
        XCTAssertEqual(OverviewNumericFormat.integerPercent.displayParts.suffix, "%")
        XCTAssertEqual(OverviewNumericFormat.integerPercent.displayParts.fractionLength, 0)
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

    func testBankedResetForecastSamplesSplit24hAnd48hAndSkipPlaceholders() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let official = Snapshot.official(
            "OpenAI",
            45,
            "7 day",
            "2d",
            date,
            windows: [
                OfficialQuotaWindow(
                    kind: .sevenDay,
                    remaining: 45,
                    label: "7 day",
                    daysText: "7d",
                    reset: "2d",
                    durationSeconds: 604_800
                )
            ],
            bankedReset: CodexBankedReset(cards: [
                CodexBankedResetCard(
                    id: "card",
                    resetType: "codex_rate_limits",
                    titleText: "Full reset",
                    expiresAt: date.addingTimeInterval(86_400),
                    expiresText: "later"
                )
            ]),
            resetForecast: .demo(updatedAt: date)
        )
        let samples = OverviewNumericPresentation.samples(
            snapshot: official,
            lunaReserveDisplayMode: .disabled,
            hideExhaustedQuota: false,
            showBankedReset: true
        )
        XCTAssertEqual(
            samples.map(\.identity),
            [
                .officialWindow(provider: "OpenAI", kind: .sevenDay),
                .bankedResetCount(provider: "OpenAI"),
                .bankedResetProbability24h(provider: "OpenAI"),
                .bankedResetProbability48h(provider: "OpenAI")
            ]
        )
        XCTAssertEqual(samples.last?.displayText, "42%")

        let strongSignalSamples = OverviewNumericPresentation.samples(
            snapshot: Snapshot.official(
                "OpenAI",
                45,
                "7 day",
                "2d",
                date,
                windows: official.officialQuotaWindows,
                bankedReset: official.bankedReset,
                resetForecast: CodexResetForecast(
                    probability24h: .percent(20),
                    probability48h: .percent(35),
                    confidence: .low,
                    updatedAt: date,
                    isCached: false,
                    officialSignal: CodexResetOfficialSignal(probability: .percent(71))
                )
            ),
            lunaReserveDisplayMode: .disabled,
            hideExhaustedQuota: false,
            showBankedReset: true
        )
        XCTAssertEqual(
            strongSignalSamples.map(\.identity),
            [
                .officialWindow(provider: "OpenAI", kind: .sevenDay),
                .bankedResetCount(provider: "OpenAI"),
                .bankedResetProbabilitySignal(provider: "OpenAI")
            ]
        )
        XCTAssertEqual(strongSignalSamples.last?.displayText, "71%")

        let countdownSamples = OverviewNumericPresentation.samples(
            snapshot: Snapshot.official(
                "OpenAI",
                45,
                "7 day",
                "2d",
                date,
                windows: official.officialQuotaWindows,
                bankedReset: official.bankedReset,
                resetForecast: CodexResetForecast(
                    probability24h: .percent(20),
                    probability48h: .percent(35),
                    confidence: .low,
                    updatedAt: date,
                    isCached: false,
                    officialSignal: CodexResetOfficialSignal(
                        probability: .percent(71),
                        targetAt: date.addingTimeInterval(3_665)
                    )
                )
            ),
            lunaReserveDisplayMode: .disabled,
            hideExhaustedQuota: false,
            showBankedReset: true,
            now: date
        )
        XCTAssertEqual(
            countdownSamples.map(\.identity),
            [
                .officialWindow(provider: "OpenAI", kind: .sevenDay),
                .bankedResetCount(provider: "OpenAI"),
                .bankedResetProbabilityCountdown(provider: "OpenAI")
            ]
        )
        XCTAssertEqual(countdownSamples.last?.displayText, "1h01m05s")
        XCTAssertEqual(countdownSamples.last?.format, .remainingSeconds)
        let countdownTick = OverviewNumericTransition.plan(
            previous: countdownSamples.last,
            current: OverviewNumericSample(
                identity: .bankedResetProbabilityCountdown(provider: "OpenAI"),
                format: .remainingSeconds,
                value: 3_664,
                progressPercentage: nil
            ),
            reduceMotion: false
        )
        XCTAssertTrue(countdownTick.animates)
        XCTAssertEqual(countdownTick.startText, "1h01m05s")
        XCTAssertEqual(countdownTick.endText, "1h01m04s")
        let reduceMotionTick = OverviewNumericTransition.plan(
            previous: countdownSamples.last,
            current: OverviewNumericSample(
                identity: .bankedResetProbabilityCountdown(provider: "OpenAI"),
                format: .remainingSeconds,
                value: 3_664,
                progressPercentage: nil
            ),
            reduceMotion: true
        )
        XCTAssertFalse(reduceMotionTick.animates)
        XCTAssertEqual(reduceMotionTick.startText, "1h01m04s")

        let fallbackSamples = OverviewNumericPresentation.samples(
            snapshot: Snapshot.official(
                "OpenAI",
                45,
                "7 day",
                "2d",
                date,
                windows: official.officialQuotaWindows,
                bankedReset: official.bankedReset,
                resetForecast: CodexResetForecast(
                    probability24h: .percent(20),
                    probability48h: .percent(35),
                    confidence: .low,
                    updatedAt: date,
                    isCached: false,
                    officialSignal: .probabilityUnavailable
                )
            ),
            lunaReserveDisplayMode: .disabled,
            hideExhaustedQuota: false,
            showBankedReset: true
        )
        XCTAssertEqual(
            fallbackSamples.map(\.identity),
            [
                .officialWindow(provider: "OpenAI", kind: .sevenDay),
                .bankedResetCount(provider: "OpenAI")
            ]
        )
        let first24 = OverviewNumericTransition.plan(
            previous: nil,
            current: samples[2],
            reduceMotion: false
        )
        XCTAssertFalse(first24.animates)
        let unchanged24 = OverviewNumericTransition.plan(
            previous: samples[2],
            current: samples[2],
            reduceMotion: false
        )
        XCTAssertFalse(unchanged24.animates)
        let changed24 = OverviewNumericTransition.plan(
            previous: samples[2],
            current: OverviewNumericSample(
                identity: .bankedResetProbability24h(provider: "OpenAI"),
                format: .integerPercent,
                value: 40,
                progressPercentage: nil
            ),
            reduceMotion: false
        )
        XCTAssertTrue(changed24.animates)
        XCTAssertEqual(changed24.startText, "24%")
        XCTAssertEqual(changed24.endText, "40%")

        let placeholders = Snapshot.official(
            "OpenAI",
            45,
            "7 day",
            "2d",
            date,
            windows: official.officialQuotaWindows,
            bankedReset: official.bankedReset,
            resetForecast: .unavailable
        )
        let placeholderSamples = OverviewNumericPresentation.samples(
            snapshot: placeholders,
            lunaReserveDisplayMode: .disabled,
            hideExhaustedQuota: false,
            showBankedReset: true
        )
        XCTAssertEqual(
            placeholderSamples.map(\.identity),
            [
                .officialWindow(provider: "OpenAI", kind: .sevenDay),
                .bankedResetCount(provider: "OpenAI")
            ]
        )
    }

    func testSameIdentityCurrencyTransitionAnimatesAndUnchangedValueDoesNot() {
        let previous = balanceSample(amount: 1.70, progress: 40)
        let current = balanceSample(amount: 1.50, progress: 30)

        let changed = OverviewNumericTransition.plan(
            previous: previous,
            current: current,
            reduceMotion: false
        )
        XCTAssertTrue(changed.animates)
        XCTAssertEqual(changed.startText, "¥1.70")
        XCTAssertEqual(changed.endText, "¥1.50")
        XCTAssertEqual(changed.startProgress, 40)
        XCTAssertEqual(changed.toProgress, 30)
        XCTAssertEqual(
            changed.format.displayText(for: 1.69),
            StatusItemController.formatBalanceSummary(1.69, unit: "CNY")
        )

        let unchanged = OverviewNumericTransition.plan(
            previous: previous,
            current: previous,
            reduceMotion: false
        )
        XCTAssertFalse(unchanged.animates)
        XCTAssertEqual(unchanged.startText, "¥1.70")
        XCTAssertEqual(unchanged.endText, "¥1.70")
        XCTAssertEqual(unchanged.startProgress, 40)
    }

    func testOpenDelayHoldsLastSeenValueForAShortBeat() {
        XCTAssertGreaterThanOrEqual(OverviewNumericTransition.openDelay, 0.18)
        XCTAssertLessThanOrEqual(OverviewNumericTransition.openDelay, 0.25)
    }

    func testCurrencyTextViewUsesDigitRollInsteadOfCountingFormattedValues() {
        let previous = balanceSample(amount: 1.70, progress: 40)
        let current = balanceSample(amount: 1.50, progress: 30)
        let plan = OverviewNumericTransition.plan(
            previous: previous,
            current: current,
            reduceMotion: false
        )
        XCTAssertEqual(OverviewNumericTransition.duration(for: plan.format), 0.32)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 31, weight: .semibold)
        let view = OverviewNumericTextView(
            text: plan.startText,
            font: font,
            value: plan.startValue
        )
        view.configure(plan: plan, sample: current)
        XCTAssertEqual(view.textField.stringValue, "¥1.70")
        XCTAssertTrue(view.hasPendingAnimationForTesting)
        XCTAssertFalse(view.isDigitRollingForTesting)
        XCTAssertTrue(view.isHostingVisibleForTesting)
        XCTAssertTrue(view.clipsToBounds)
        XCTAssertTrue(view.hostingClipsToBoundsForTesting)
        XCTAssertEqual(view.layer?.masksToBounds, true)

        view.playPendingIfNeeded()
        XCTAssertFalse(view.hasPendingAnimationForTesting)
        XCTAssertTrue(view.isDigitRollingForTesting)
        XCTAssertTrue(view.isHostingVisibleForTesting)
        XCTAssertTrue(view.textField.isHidden)
        XCTAssertEqual(view.textField.alphaValue, 0)
        XCTAssertEqual(view.currentValue, 1.50)
        XCTAssertEqual(view.textField.stringValue, "¥1.50")
        XCTAssertEqual(plan.format.displayParts.prefix, "¥")
        XCTAssertEqual(plan.format.displayParts.fractionLength, 2)
        XCTAssertEqual(view.verticalAlignment, .center)
        XCTAssertEqual(view.contentAlignmentForTesting, .trailing)
    }

    func testNumericFrameAlignmentContractPinsOnlyTopVerticalAlignment() {
        XCTAssertEqual(
            OverviewNumericTextView.contentAlignment(horizontal: .right, vertical: .center),
            .trailing
        )
        XCTAssertEqual(
            OverviewNumericTextView.contentAlignment(horizontal: .right, vertical: .top),
            .topTrailing
        )
        XCTAssertEqual(
            OverviewNumericTextView.contentAlignment(horizontal: .left, vertical: .center),
            .leading
        )
        XCTAssertEqual(
            OverviewNumericTextView.contentAlignment(horizontal: .left, vertical: .top),
            .topLeading
        )
        XCTAssertEqual(
            OverviewNumericTextView.contentAlignment(horizontal: .natural, vertical: .center),
            .leading
        )
        XCTAssertEqual(
            OverviewNumericTextView.contentAlignment(horizontal: .center, vertical: .top),
            .topTrailing
        )
    }

    func testTopAlignedCurrencyKeepsItsFrameWhileDigitsRoll() {
        let previous = balanceSample(amount: 1.70, progress: 40)
        let current = balanceSample(amount: 1.50, progress: 30)
        let plan = OverviewNumericTransition.plan(
            previous: previous,
            current: current,
            reduceMotion: false
        )
        let font = NSFont.monospacedDigitSystemFont(ofSize: 31, weight: .semibold)
        let view = OverviewNumericTextView(
            text: plan.startText,
            font: font,
            value: plan.startValue,
            verticalAlignment: .top
        )
        let amountFrame = OpenCodexCardLayout.frames(for: .balance, linkPrefixWidth: 62).amount
        view.frame = amountFrame
        view.layoutSubtreeIfNeeded()
        view.configure(plan: plan, sample: current)

        XCTAssertEqual(view.frame, amountFrame)
        XCTAssertEqual(view.verticalAlignment, .top)
        XCTAssertEqual(view.contentAlignmentForTesting, .topTrailing)
        XCTAssertTrue(view.hostsFullBoundsForTesting)
        XCTAssertTrue(view.hasPendingAnimationForTesting)

        view.playPendingIfNeeded()

        XCTAssertEqual(view.frame, amountFrame)
        XCTAssertEqual(view.verticalAlignment, .top)
        XCTAssertEqual(view.contentAlignmentForTesting, .topTrailing)
        XCTAssertTrue(view.hostsFullBoundsForTesting)
        XCTAssertTrue(view.isDigitRollingForTesting)
        XCTAssertFalse(view.hasPendingAnimationForTesting)
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

    private func balanceSample(amount: Double, progress: Double) -> OverviewNumericSample {
        OverviewNumericSample(
            identity: .thirdPartyBalance(provider: "Provider", unit: "CNY"),
            format: .currency(unit: "CNY"),
            value: amount,
            progressPercentage: progress
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

    func testThirdPartyBalanceReopenStartsFromLastSeenAmountAndProgress() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.overviewNumericReduceMotionForTesting = false
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let input = makeMenuInput(activeClient: .grok)
        let settings = makeSettings()

        controller.start(
            snapshot: Snapshot.balance("Provider", 1.70, "CNY", nil, date, progressPercentage: 40),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        let firstOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(amountTexts(in: firstOverview), ["¥1.70"])
        XCTAssertEqual(progressValues(in: firstOverview), [40])
        XCTAssertFalse(amountViews(in: firstOverview).contains { $0.hasPendingAnimationForTesting })

        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.menuDidClose(controller.statusMenuForTesting)
        XCTAssertEqual(
            controller.lastSeenOverviewNumericsForTesting[thirdPartyBalance]?.displayText,
            "¥1.70"
        )
        XCTAssertEqual(
            controller.lastSeenOverviewNumericsForTesting[thirdPartyBalance]?.progressPercentage,
            40
        )

        controller.update(
            snapshot: Snapshot.balance("Provider", 1.50, "CNY", nil, date, progressPercentage: 30),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        let secondOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(amountTexts(in: secondOverview), ["¥1.70"])
        XCTAssertEqual(progressValues(in: secondOverview), [40])
        XCTAssertTrue(amountViews(in: secondOverview).contains { $0.hasPendingAnimationForTesting })
        XCTAssertTrue(progressViews(in: secondOverview).contains { $0.hasPendingAnimationForTesting })
        XCTAssertEqual(
            controller.menuBarPrimaryTextForTesting,
            Snapshot.balance("Provider", 1.50, "CNY", nil, date, progressPercentage: 30).menuBarPrimary
        )
        XCTAssertNotEqual(controller.menuBarPrimaryTextForTesting, "¥1.70")
    }

    func testMenuOpenHoldsLastSeenValuesUntilOpenDelayElapses() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.overviewNumericReduceMotionForTesting = false
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let input = makeMenuInput(activeClient: .grok)
        let settings = makeSettings()

        controller.start(
            snapshot: Snapshot.balance("Provider", 1.70, "CNY", nil, date, progressPercentage: 40),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.menuDidClose(controller.statusMenuForTesting)
        controller.update(
            snapshot: Snapshot.balance("Provider", 1.50, "CNY", nil, date, progressPercentage: 30),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        controller.menuWillOpen(controller.statusMenuForTesting)
        defer { controller.menuDidClose(controller.statusMenuForTesting) }
        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(amountTexts(in: overview), ["¥1.70"])
        XCTAssertEqual(progressValues(in: overview), [40])
        XCTAssertTrue(amountViews(in: overview).contains { $0.hasPendingAnimationForTesting })
        XCTAssertFalse(amountViews(in: overview).contains { $0.isDigitRollingForTesting })
        XCTAssertTrue(amountViews(in: overview).allSatisfy(\.isHostingVisibleForTesting))
        XCTAssertTrue(progressViews(in: overview).contains { $0.hasPendingAnimationForTesting })
        XCTAssertTrue(overview.clipsToBounds)
        XCTAssertEqual(overview.layer?.masksToBounds, true)
        XCTAssertEqual(
            controller.menuBarPrimaryTextForTesting,
            Snapshot.balance("Provider", 1.50, "CNY", nil, date, progressPercentage: 30).menuBarPrimary
        )
    }

    func testThirdPartyBalanceUnchangedValueDoesNotAnimate() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.overviewNumericReduceMotionForTesting = false
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let input = makeMenuInput(activeClient: .grok)
        let settings = makeSettings()
        let snapshot = Snapshot.balance("Provider", 1.70, "CNY", nil, date, progressPercentage: 40)

        controller.start(
            snapshot: snapshot,
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.menuDidClose(controller.statusMenuForTesting)
        controller.update(
            snapshot: snapshot,
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(amountTexts(in: overview), ["¥1.70"])
        XCTAssertEqual(progressValues(in: overview), [40])
        XCTAssertFalse(amountViews(in: overview).contains { $0.hasPendingAnimationForTesting })
        XCTAssertFalse(progressViews(in: overview).contains { $0.hasPendingAnimationForTesting })
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

    func testBalanceAmountIsTopAlignedWhileOtherNumericCardsStayCentered() throws {
        let previousOverride = LunaReserveUserFacing.testOverride
        LunaReserveUserFacing.testOverride = true
        defer { LunaReserveUserFacing.testOverride = previousOverride }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let balanceController = makeController()
        defer { balanceController.teardown() }
        balanceController.start(
            snapshot: Snapshot.balance("Provider", 1.02, "USD", nil, date, progressPercentage: 40),
            refreshDate: date,
            menuInput: makeMenuInput(activeClient: .grok),
            settings: makeSettings()
        )
        let balanceOverview = try XCTUnwrap(balanceController.menuItemsForTesting.first?.view)
        let balanceAmounts = amountViews(in: balanceOverview)
        XCTAssertEqual(balanceAmounts.count, 1)
        let balanceAmount = try XCTUnwrap(balanceAmounts.first)
        let balanceLayout = OpenCodexCardLayout.frames(
            for: .balance,
            linkPrefixWidth: AppLanguage.resolved.overviewLinkPrefixWidth
        )
        XCTAssertEqual(balanceAmount.frame, balanceLayout.amount)
        XCTAssertEqual(balanceLayout.amount, CGRect(x: 149, y: 10, width: 141, height: 48))
        XCTAssertEqual(balanceAmount.verticalAlignment, .top)
        XCTAssertEqual(balanceAmount.contentAlignmentForTesting, .topTrailing)

        let hiddenProgressController = makeController()
        defer { hiddenProgressController.teardown() }
        let hiddenProgressSettings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true,
            showQuotaProgressBar: false
        )
        hiddenProgressController.start(
            snapshot: Snapshot.balance("Provider", 1.02, "USD", nil, date, progressPercentage: 40),
            refreshDate: date,
            menuInput: makeMenuInput(activeClient: .grok),
            settings: hiddenProgressSettings
        )
        let hiddenOverview = try XCTUnwrap(hiddenProgressController.menuItemsForTesting.first?.view)
        let hiddenAmount = try XCTUnwrap(amountViews(in: hiddenOverview).first)
        let hiddenLayout = OpenCodexCardLayout.frames(
            for: .balance,
            linkPrefixWidth: AppLanguage.resolved.overviewLinkPrefixWidth,
            includesQuotaProgress: false
        )
        XCTAssertEqual(hiddenAmount.frame, hiddenLayout.amount)
        XCTAssertEqual(hiddenLayout.amount.height, 48)
        XCTAssertEqual(hiddenLayout.amount.maxY, hiddenLayout.quotaDetail.maxY + 1)
        XCTAssertEqual(hiddenAmount.verticalAlignment, .top)
        XCTAssertEqual(hiddenAmount.contentAlignmentForTesting, .topTrailing)
        XCTAssertTrue(progressViews(in: hiddenOverview).isEmpty)

        let officialController = makeController()
        defer { officialController.teardown() }
        officialController.start(
            snapshot: Snapshot.official(
                "OpenAI Official",
                45,
                "7 day",
                "2d",
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
                ],
                lunaReserve: LunaReserveQuota(
                    status: .available,
                    remaining: 80,
                    reset: "1h"
                ),
                bankedReset: CodexBankedReset(cards: [
                    CodexBankedResetCard(
                        id: "card",
                        resetType: "codex_rate_limits",
                        titleText: "Full reset",
                        expiresAt: date.addingTimeInterval(86_400),
                        expiresText: "later"
                    )
                ]),
                resetForecast: .demo(updatedAt: date)
            ),
            refreshDate: date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        let officialOverview = try XCTUnwrap(officialController.menuItemsForTesting.first?.view)
        assertCentered(
            .officialWindow(provider: "OpenAI Official", kind: .fiveHour),
            horizontal: .trailing,
            in: officialOverview
        )
        assertCentered(
            .officialWindow(provider: "OpenAI Official", kind: .sevenDay),
            horizontal: .trailing,
            in: officialOverview
        )
        assertCentered(
            .lunaReserve(provider: "OpenAI Official"),
            horizontal: .trailing,
            in: officialOverview
        )
        assertCentered(
            .bankedResetCount(provider: "OpenAI Official"),
            horizontal: .trailing,
            in: officialOverview
        )
        assertCentered(
            .bankedResetProbability24h(provider: "OpenAI Official"),
            horizontal: .leading,
            in: officialOverview
        )
        assertCentered(
            .bankedResetProbability48h(provider: "OpenAI Official"),
            horizontal: .leading,
            in: officialOverview
        )
    }

    private func assertCentered(
        _ identity: OverviewNumericIdentity,
        horizontal: OverviewNumericContentAlignment,
        in overview: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identifier = OverviewNumericPresentation.amountIdentifier(for: identity)
        let view = amountViews(in: overview).first { $0.identifier == identifier }
        XCTAssertNotNil(view, "missing numeric view \(identifier.rawValue)", file: file, line: line)
        XCTAssertEqual(view?.verticalAlignment, .center, file: file, line: line)
        XCTAssertEqual(view?.contentAlignmentForTesting, horizontal, file: file, line: line)
    }

    private var fiveHour: OverviewNumericIdentity {
        .officialWindow(provider: "OpenAI Official", kind: .fiveHour)
    }

    private var thirdPartyBalance: OverviewNumericIdentity {
        .thirdPartyBalance(provider: "Provider", unit: "CNY")
    }

    private func amountViews(in view: NSView) -> [OverviewNumericTextView] {
        descendantViews(of: view, as: OverviewNumericTextView.self)
    }

    private func amountTexts(in view: NSView) -> [String] {
        amountViews(in: view).map(\.textField.stringValue)
    }

    private func progressViews(in view: NSView) -> [QuotaProgressView] {
        descendantViews(of: view, as: QuotaProgressView.self)
    }

    private func progressValues(in view: NSView) -> [Double] {
        progressViews(in: view).map(\.percentage)
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
