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
            OverviewNumericFormat.remainingMinutes.displayText(for: 239),
            "3h59m"
        )
        XCTAssertEqual(
            OverviewNumericFormat.remainingMinutes.displayText(for: 83),
            "1h23m"
        )
        XCTAssertEqual(
            OverviewNumericFormat.remainingMinutes.displayText(for: 12),
            "12m"
        )
        XCTAssertEqual(OverviewNumericFormat.remainingMinutes.displayText(for: 0), "0m")
        XCTAssertTrue(OverviewNumericFormat.remainingMinutes.displayParts.remainingTime)

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
        XCTAssertEqual(countdownSamples.last?.displayText, "1h1m")
        XCTAssertEqual(countdownSamples.last?.format, .remainingMinutes)
        XCTAssertEqual(countdownSamples.last?.value, 61)
        let sameMinuteTick = OverviewNumericTransition.plan(
            previous: countdownSamples.last,
            current: OverviewNumericSample(
                identity: .bankedResetProbabilityCountdown(provider: "OpenAI"),
                format: .remainingMinutes,
                value: 61,
                progressPercentage: nil
            ),
            reduceMotion: false
        )
        XCTAssertFalse(sameMinuteTick.animates)
        XCTAssertEqual(sameMinuteTick.startText, "1h1m")
        XCTAssertEqual(sameMinuteTick.endText, "1h1m")
        let countdownTick = OverviewNumericTransition.plan(
            previous: countdownSamples.last,
            current: OverviewNumericSample(
                identity: .bankedResetProbabilityCountdown(provider: "OpenAI"),
                format: .remainingMinutes,
                value: 59,
                progressPercentage: nil
            ),
            reduceMotion: false
        )
        XCTAssertTrue(countdownTick.animates)
        XCTAssertEqual(countdownTick.startText, "1h1m")
        XCTAssertEqual(countdownTick.endText, "59m")
        let reduceMotionTick = OverviewNumericTransition.plan(
            previous: countdownSamples.last,
            current: OverviewNumericSample(
                identity: .bankedResetProbabilityCountdown(provider: "OpenAI"),
                format: .remainingMinutes,
                value: 59,
                progressPercentage: nil
            ),
            reduceMotion: true
        )
        XCTAssertFalse(reduceMotionTick.animates)
        XCTAssertEqual(reduceMotionTick.startText, "59m")

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
    private lazy var predictionStore: CodexResetObservationStore = {
        let name = "BalanceBarTests.pace-context.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return CodexResetObservationStore(defaults: defaults)
    }()
    private func timedPaceSnapshot(now: Date, remaining: Double, resetAt: Date? = nil) -> Snapshot {
        let reset = resetAt ?? now.addingTimeInterval(9_000)
        let windows = [OfficialQuotaWindow(kind: .fiveHour, remaining: remaining,
            label: "5h", daysText: "5h", reset: "obsolete", durationSeconds: 18_000, resetAt: reset)]
        return Snapshot.official("OpenAI Official", remaining, "5h", "obsolete", now,
            windows: windows, quotaPredictionContexts: predictionStore.updatePredictionContexts(
                providerID: "official", accountKey: "pace@example.com", windows: windows, now: now),
            quotaPredictionAccountKey: "pace@example.com")
    }

    @MainActor
    func testDeactivationBeforeDidCloseDefersEveryContentMutationAndAppliesLatestOnOpen() throws {
        var lines: [String] = []
        MenuDismissalTrace.sinkForTesting = { lines.append($0) }
        defer { MenuDismissalTrace.sinkForTesting = nil }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = makeController()
        defer { controller.teardown() }
        controller.quotaPaceNowForTesting = now
        controller.bankedResetCountdownNowForTesting = now
        controller.overviewNumericReduceMotionForTesting = true
        func snapshot(remaining: Double, onlyWeek: Bool) -> Snapshot {
            let windows = [
                OfficialQuotaWindow(kind: .fiveHour, remaining: remaining, label: "5h", daysText: "5h",
                    reset: nil, durationSeconds: 18_000, resetAt: now.addingTimeInterval(9_000)),
                OfficialQuotaWindow(kind: .sevenDay, remaining: remaining, label: "7d", daysText: "7d",
                    reset: nil, durationSeconds: 604_800, resetAt: now.addingTimeInterval(302_400))
            ]
            return .official("OpenAI Official", remaining, "quota", nil, now,
                windows: onlyWeek ? [windows[1]] : windows, bankedReset: CodexBankedReset(cards: []),
                resetForecast: CodexResetForecast(probability24h: .percent(20), probability48h: .percent(35),
                    confidence: .low, updatedAt: now, isCached: false,
                    officialSignal: CodexResetOfficialSignal(probability: .percent(71), targetAt: now.addingTimeInterval(3_665))))
        }
        func descendants(_ node: NSView) -> [NSView] { node.subviews.flatMap { [$0] + descendants($0) } }
        controller.start(snapshot: snapshot(remaining: 40, onlyWeek: false), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        let outgoingMenu = controller.statusMenuForTesting
        controller.menuWillOpen(outgoingMenu)
        let host = try XCTUnwrap(controller.menuItemsForTesting.first?.view as? MenuHoverLinkHostView)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        ApplicationWindowPresentation.presentInBackground(window)
        defer { window.orderOut(nil); host.finishMenuDismissal() }
        let countdown = try XCTUnwrap(descendants(host).compactMap { $0 as? OverviewNumericHoverLinkTextField }
            .first { $0.sample?.format == .remainingMinutes })
        let countdownValue = countdown.sample?.value
        let timer = try XCTUnwrap(controller.bankedResetCountdownTimerForTesting)
        let paceTimer = try XCTUnwrap(controller.quotaPaceTimerForTesting)
        let views = host.paceViews
        let sections = host.subviews.map(ObjectIdentifier.init)
        let labels = descendants(host).compactMap { ($0 as? NSTextField)?.stringValue }
        let items = controller.menuItemsForTesting.map(ObjectIdentifier.init)
        let rebuilds = controller.statusMenuRebuildCountForTesting
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertTrue(host.isMenuDismissing)
        let deadline = Date().addingTimeInterval(OverviewNumericTransition.openDelay + 0.05)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }
        controller.bankedResetCountdownNowForTesting = now.addingTimeInterval(120)
        controller.quotaPaceNowForTesting = now.addingTimeInterval(120)
        timer.fire()
        paceTimer.fire()
        // Numeric-only refresh, then a structural change, both in the gap
        // before AppKit delivers menuDidClose.
        for onlyWeek in [false, true] {
            controller.update(snapshot: snapshot(remaining: 10, onlyWeek: onlyWeek), refreshDate: now.addingTimeInterval(120),
                menuInput: makeMenuInput(), settings: makeSettings())
            XCTAssertEqual(host.subviews.map(ObjectIdentifier.init), sections)
            XCTAssertEqual(host.paceViews.map(ObjectIdentifier.init), views.map(ObjectIdentifier.init))
            XCTAssertEqual(descendants(host).compactMap { ($0 as? NSTextField)?.stringValue }, labels)
            XCTAssertTrue(views.allSatisfy { $0.progress.percentage == 40 && $0.pace?.roundedActual == 40 })
        }
        XCTAssertEqual(countdown.sample?.value, countdownValue)
        XCTAssertEqual(controller.menuItemsForTesting.map(ObjectIdentifier.init), items)
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, rebuilds)
        XCTAssertTrue(controller.statusMenuNeedsRebuildForTesting)
        for source in ["sections", "numerics", "numerics.open", "pace", "countdown.timer"] {
            XCTAssertTrue(lines.contains { $0.contains("event=content.update.deferred;") && $0.contains("source=\(source)") })
        }
        controller.menuDidClose(outgoingMenu)
        let nextMenu = controller.statusMenuForTesting
        XCTAssertFalse(nextMenu === outgoingMenu,
            "Prepare an independent next menu while the old window finishes dismissal")
        XCTAssertFalse(nextMenu.items.first?.view === host)
        host.finishMenuDismissal() // Auxiliary cleanup must not restore a still-visible window.
        XCTAssertTrue(host.isMenuDismissing)
        XCTAssertTrue(window.isVisible)
        controller.update(snapshot: snapshot(remaining: 10, onlyWeek: true), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        // The counter includes building the independent next menu. Protect
        // the actual outgoing tree rather than forbidding all new-menu work.
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, rebuilds + 1)
        XCTAssertTrue(controller.statusMenuForTesting === nextMenu)
        XCTAssertTrue(outgoingMenu.items.first?.view === host)
        XCTAssertTrue(host.window === window)
        XCTAssertEqual(outgoingMenu.items.map(ObjectIdentifier.init), items)
        XCTAssertEqual(host.subviews.map(ObjectIdentifier.init), sections)
        XCTAssertEqual(host.paceViews.map(ObjectIdentifier.init), views.map(ObjectIdentifier.init))
        XCTAssertEqual(descendants(host).compactMap { ($0 as? NSTextField)?.stringValue }, labels)
        XCTAssertTrue(views.allSatisfy { $0.progress.percentage == 40 && $0.pace?.roundedActual == 40 })
        XCTAssertEqual(countdown.sample?.value, countdownValue)
        controller.menuWillOpen(nextMenu)
        let latest = try XCTUnwrap(controller.menuItemsForTesting.first?.view as? MenuHoverLinkHostView)
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, rebuilds + 1)
        XCTAssertEqual(latest.paceViews.count, 1)
        XCTAssertEqual(latest.paceViews.first?.quotaWindow.kind, .sevenDay)
        XCTAssertEqual(latest.paceViews.first?.progress.percentage, 10)
        let latestCountdown = try XCTUnwrap(descendants(latest).compactMap { $0 as? OverviewNumericHoverLinkTextField }
            .first { $0.sample?.format == .remainingMinutes })
        XCTAssertEqual(latestCountdown.sample?.value, 59)
        controller.menuDidClose(controller.statusMenuForTesting)
    }

    func testAggregatedCodexCardsUseOwnAccountsShareTimersAndRespectCardDismissal() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func display(_ index: Int, email: String, remaining: Double = 40) -> AggregatedProviderDisplay {
            let windows = [OfficialQuotaWindow(kind: .fiveHour, remaining: remaining, label: "5h", daysText: "5h", reset: nil,
                durationSeconds: 18_000, resetAt: now.addingTimeInterval(9_000))]
            let id = "codex-\(index)"
            let contexts = predictionStore.updatePredictionContexts(providerID: id, accountKey: email, windows: windows, now: now)
            return AggregatedProviderDisplay(
                entry: AggregatedProviderEntry(source: ProviderSummarySource(id: id, name: id, isOfficial: true,
                    query: nil, officialAccessToken: nil, notes: nil), role: index == 0 ? .default : .member),
                identity: AggregationDisplayIdentity(providerID: id, accountScope: email, configurationRevision: "fixture"),
                snapshot: .official("OpenAI Official", remaining, "5h", nil, now, windows: windows,
                    resetForecast: CodexResetForecast(probability24h: .percent(20), probability48h: .percent(35),
                        confidence: .low, updatedAt: now, isCached: false,
                        officialSignal: CodexResetOfficialSignal(probability: .percent(71), targetAt: now.addingTimeInterval(3_665))),
                    quotaPredictionContexts: contexts, quotaPredictionAccountKey: email),
                account: OpenAIAccountPresentation(email: email), status: .fresh, reason: nil, fetchedAt: now)
        }
        // The active account is A; card B belongs to another account.
        func input(remainingB: Double = 40) -> StatusItemController.MenuInput {
            StatusItemController.MenuInput(choices: [], quickSwitchSummaries: [:], activeClient: .codex,
                openAIAccount: OpenAIAccountPresentation(email: "pace@example.com"), statusLinks: [],
                showQuickSwitchMenu: true, showOpenChatGPTMenu: true, showOpenCCSwitchMenu: true, showStatusMenu: false,
                aggregatedProviders: [display(0, email: "pace@example.com"),
                    display(1, email: "other@example.com", remaining: remainingB)],
                aggregationQuickSwitchBlocked: true)
        }
        let controller = makeController()
        defer { controller.teardown() }
        controller.quotaPaceNowForTesting = now
        controller.bankedResetCountdownNowForTesting = now
        controller.overviewNumericReduceMotionForTesting = true
        controller.start(snapshot: .placeholder, refreshDate: now, menuInput: input(), settings: makeSettings())
        controller.menuWillOpen(controller.statusMenuForTesting)
        defer { controller.menuDidClose(controller.statusMenuForTesting) }
        let viewport = try XCTUnwrap(controller.statusMenuForTesting.items.first?.view as? AggregationOverviewScrollView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 600), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = viewport
        ApplicationWindowPresentation.presentInBackground(window)
        defer { window.orderOut(nil) }
        let cards = viewport.cardHosts()
        XCTAssertEqual(cards.count, 2)
        let paces = try cards.map { try XCTUnwrap($0.paceViews.first) }
        XCTAssertNotNil(paces[0].prediction)
        XCTAssertNotNil(paces[1].prediction, "card B is validated against its own account")

        let paceTimer = try XCTUnwrap(controller.quotaPaceTimerForTesting, "one menu-level pace timer")
        XCTAssertNotNil(controller.bankedResetCountdownTimerForTesting, "aggregated countdown runs")
        let before = paces.map(\.prediction)
        controller.quotaPaceNowForTesting = now.addingTimeInterval(60)
        paceTimer.fire()
        XCTAssertNotEqual(paces[0].prediction, before[0])
        XCTAssertNotEqual(paces[1].prediction, before[1])

        // A data refresh for card B keeps its own-account identity: the pace
        // view and its prediction survive instead of being reset as foreign.
        controller.updateMenu(input: input(remainingB: 35))
        XCTAssertTrue(cards[1].paceViews.first === paces[1], "card B keeps its pace view")
        XCTAssertNotNil(paces[1].prediction, "card B keeps its prediction")
        XCTAssertEqual(paces[1].progress.percentage, 35)

        // Card B starts dismissing while the controller still tracks the menu.
        cards[1].setMenuContentVisible(false)
        XCTAssertTrue(cards[1].isMenuDismissing)
        let frozen = paces[1].prediction
        controller.quotaPaceNowForTesting = now.addingTimeInterval(120)
        paceTimer.fire()
        XCTAssertNotEqual(paces[0].prediction, frozen)
        XCTAssertEqual(paces[1].prediction, frozen, "a dismissing card is never mutated")
        XCTAssertEqual(paces[1].progress.percentage, 35)
        controller.updateMenu(input: input(remainingB: 30))
        XCTAssertEqual(paces[1].progress.percentage, 35, "new data waits for the closed rebuild")
        XCTAssertTrue(controller.statusMenuNeedsRebuildForTesting)
        cards[1].finishMenuDismissal(beforeOpening: true)
    }

    func testWeeklyPredictionConsumesMatchingContextAndMinuteTickKeepsViews() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let windows = [
            OfficialQuotaWindow(kind: .fiveHour, remaining: 40, label: "5h", daysText: "5h", reset: nil,
                durationSeconds: 18_000, resetAt: now.addingTimeInterval(9000)),
            OfficialQuotaWindow(kind: .sevenDay, remaining: 40, label: "7d", daysText: "7d", reset: nil,
                durationSeconds: 604_800, resetAt: now.addingTimeInterval(302_400))]
        let contexts = predictionStore.updatePredictionContexts(providerID: "official", accountKey: "pace@example.com",
            windows: windows, now: now)
        func snapshot(account: String = "pace@example.com", contexts: [QuotaPredictionContext]) -> Snapshot {
            .official("OpenAI Official", 40, "7d", nil, now, windows: windows,
                quotaPredictionContexts: contexts, quotaPredictionAccountKey: account)
        }
        let controller = makeController()
        defer { controller.teardown() }
        controller.quotaPaceNowForTesting = now
        controller.start(snapshot: snapshot(contexts: []), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        let host = try XCTUnwrap(controller.menuItemsForTesting.first?.view as? MenuHoverLinkHostView)
        XCTAssertTrue(host.paceViews.allSatisfy { $0.prediction == nil }, "No UI metadata inference without a coordinator context")
        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.update(snapshot: snapshot(account: "other@example.com", contexts: contexts), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        XCTAssertTrue(host.paceViews.allSatisfy { $0.prediction == nil })
        controller.update(snapshot: snapshot(contexts: contexts), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        let weekly = try XCTUnwrap(host.paceViews.first { $0.quotaWindow.kind == .sevenDay })
        XCTAssertNotNil(weekly.prediction)
        let prediction = weekly.prediction
        controller.quotaPaceNowForTesting = now.addingTimeInterval(60)
        try XCTUnwrap(controller.quotaPaceTimerForTesting).fire()
        XCTAssertTrue(controller.menuItemsForTesting.first?.view === host)
        XCTAssertTrue(host.paceViews.contains { $0 === weekly })
        XCTAssertNotEqual(weekly.prediction, prediction)
        XCTAssertTrue(host.paceViews.allSatisfy { $0.prediction != nil })
        // A context for a different deadline cannot qualify the current weekly window.
        let wrongWindow = OfficialQuotaWindow(kind: .sevenDay, remaining: 40, label: "7d", daysText: "7d", reset: nil,
            durationSeconds: 604_800, resetAt: now.addingTimeInterval(320_000))
        let wrong = QuotaPredictionContext(cycle: try XCTUnwrap(QuotaPredictionCycle(window: wrongWindow)),
            inferredCycleStart: now.addingTimeInterval(-284_800))
        controller.update(snapshot: snapshot(contexts: contexts.filter { $0.cycle.kind == .fiveHour } + [wrong]), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        XCTAssertNil(weekly.prediction)
        XCTAssertNotNil(host.paceViews.first { $0.quotaWindow.kind == .fiveHour }?.prediction)
        controller.menuDidClose(controller.statusMenuForTesting)
        XCTAssertNil(controller.quotaPaceTimerForTesting)
    }

    func testPaceMinuteTickAndQuotaRefreshKeepExistingProgressAndView() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(9_000)
        let controller = makeController()
        defer { controller.teardown() }
        controller.quotaPaceNowForTesting = now
        controller.overviewNumericReduceMotionForTesting = true
        controller.start(snapshot: timedPaceSnapshot(now: now, remaining: 40), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        let host = try XCTUnwrap(controller.menuItemsForTesting.first?.view as? MenuHoverLinkHostView)
        let pace = try XCTUnwrap(host.paceViews.first)
        XCTAssertNil(controller.quotaPaceTimerForTesting)
        XCTAssertEqual(pace.progress.identifier, OverviewNumericPresentation.progressIdentifier(for: pace.numericIdentity))
        let rebuilds = controller.statusMenuRebuildCountForTesting
        controller.quotaPaceNowForTesting = now.addingTimeInterval(60)
        controller.menuWillOpen(controller.statusMenuForTesting)
        XCTAssertEqual(try XCTUnwrap(pace.pace?.expectedRemaining), 100 * 8_940.0 / 18_000, accuracy: 0.0001)
        let initialPrediction = pace.prediction
        XCTAssertNotNil(initialPrediction)
        let timer = try XCTUnwrap(controller.quotaPaceTimerForTesting)
        XCTAssertEqual(timer.timeInterval, 60)
        controller.quotaPaceNowForTesting = now.addingTimeInterval(120)
        timer.fire()
        XCTAssertNotEqual(pace.prediction, initialPrediction)
        XCTAssertEqual(try XCTUnwrap(pace.pace?.expectedRemaining), 100 * 8_880.0 / 18_000, accuracy: 0.0001)
        XCTAssertTrue(controller.menuItemsForTesting.first?.view === host)
        XCTAssertEqual(controller.statusMenuRebuildCountForTesting, rebuilds)
        controller.update(snapshot: timedPaceSnapshot(now: now, remaining: 35, resetAt: reset), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        XCTAssertTrue(host.paceViews.first === pace)
        XCTAssertEqual(pace.progress.percentage, 35)
        XCTAssertEqual(pace.pace?.roundedActual, 35)
        controller.menuDidClose(controller.statusMenuForTesting)
        XCTAssertNil(controller.quotaPaceTimerForTesting)
        XCTAssertFalse(timer.isValid)
        XCTAssertFalse(pace.isMenuTracking)
    }

    func testPaceAnimationRuntimePolicyUsesExistingWorkspaceObserver() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = makeController()
        defer { controller.teardown() }
        controller.quotaPaceNowForTesting = now
        controller.start(snapshot: timedPaceSnapshot(now: now, remaining: 40), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        let host = try XCTUnwrap(controller.menuItemsForTesting.first?.view as? MenuHoverLinkHostView)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        controller.menuWillOpen(controller.statusMenuForTesting)
        let view = try XCTUnwrap(host.paceViews.first)
        let sections = Array(host.sectionFocus.sections.values)
        sections.forEach { $0.focusReduceMotionForTesting = false; $0.focusReduceTransparencyForTesting = false }
        view.markerReduceMotionForTesting = false
        view.updateHover(at: NSPoint(x: view.markerCenterX, y: view.bounds.midY))
        XCTAssertNotNil(view.markerLayerForTesting.bodyLayer.animationKeys())
        host.sectionFocus.pendingTimerForTesting?.fire()
        let receded = try XCTUnwrap(sections.first { $0.focusState == .receded })
        XCTAssertNotNil(receded.layer?.animation(forKey: "sectionFocus.radius"))
        sections.forEach { $0.focusReduceMotionForTesting = true; $0.focusReduceTransparencyForTesting = true }
        view.markerReduceMotionForTesting = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertNil(view.markerLayerForTesting.bodyLayer.animationKeys())
        XCTAssertEqual(view.markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.hoverSize)
        XCTAssertEqual(receded.alphaValue, 0.5)
        XCTAssertTrue(receded.contentFilters.isEmpty)
        XCTAssertNil(receded.layer?.animation(forKey: "sectionFocus.radius"))
        sections.forEach { $0.focusReduceMotionForTesting = false; $0.focusReduceTransparencyForTesting = false }
        view.markerReduceMotionForTesting = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertNil(view.markerLayerForTesting.bodyLayer.animationKeys())
        XCTAssertFalse(receded.contentFilters.isEmpty)
        XCTAssertNil(receded.layer?.animation(forKey: "sectionFocus.radius"), "Disabling Reduce Motion does not replay")
        controller.menuDidClose(controller.statusMenuForTesting)
        XCTAssertTrue(sections.allSatisfy { $0.alphaValue == 1 && $0.contentFilters.isEmpty })
        XCTAssertEqual(view.markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.restSize)
        XCTAssertFalse(view.hasPendingShowForTesting)
    }

    func testPaceTooltipUsesSettingsTimezoneAtCreationAndOpenRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = makeController()
        defer { controller.teardown() }
        controller.quotaPaceNowForTesting = now
        let input = makeMenuInput()
        controller.start(snapshot: timedPaceSnapshot(now: now, remaining: 40), refreshDate: now,
            menuInput: input, settings: makeSettings(timeZone: TimeZone(secondsFromGMT: 8 * 3600)!))
        let host = try XCTUnwrap(controller.menuItemsForTesting.first?.view as? MenuHoverLinkHostView)
        let pace = try XCTUnwrap(host.paceViews.first)
        XCTAssertTrue(try XCTUnwrap(pace.tooltipContent?.body).contains("07:55"))
        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.update(snapshot: timedPaceSnapshot(now: now, remaining: 40), refreshDate: now,
            menuInput: input, settings: makeSettings(timeZone: TimeZone(secondsFromGMT: 0)!))
        XCTAssertTrue(host.paceViews.first === pace)
        XCTAssertTrue(try XCTUnwrap(pace.tooltipContent?.body).contains("23:55"))
        controller.menuDidClose(controller.statusMenuForTesting)
    }

    func testPaceInvalidWindowCanRecoverInPlaceAndIdentitySwitchClearsIt() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = makeController()
        defer { controller.teardown() }
        controller.quotaPaceNowForTesting = now
        controller.start(snapshot: timedPaceSnapshot(now: now, remaining: 60, resetAt: now), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        let host = try XCTUnwrap(controller.menuItemsForTesting.first?.view as? MenuHoverLinkHostView)
        let pace = try XCTUnwrap(host.paceViews.first)
        controller.menuWillOpen(controller.statusMenuForTesting)
        XCTAssertNil(pace.pace)
        XCTAssertNil(controller.quotaPaceTimerForTesting)
        controller.update(snapshot: timedPaceSnapshot(now: now, remaining: 60), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        XCTAssertNotNil(pace.pace)
        XCTAssertNotNil(controller.quotaPaceTimerForTesting)
        controller.quotaPaceNowForTesting = now.addingTimeInterval(9_000)
        controller.quotaPaceTimerForTesting?.fire()
        XCTAssertNil(pace.pace)
        XCTAssertNil(controller.quotaPaceTimerForTesting)
        controller.quotaPaceNowForTesting = now
        controller.update(snapshot: timedPaceSnapshot(now: now, remaining: 60), refreshDate: now,
            menuInput: makeMenuInput(activeClient: .claude), settings: makeSettings())
        XCTAssertNil(pace.pace)
        XCTAssertTrue(pace.markerHitRect.isEmpty)
        XCTAssertFalse(pace.isMenuTracking)
        let replacement = try XCTUnwrap(host.paceViews.first)
        XCTAssertFalse(replacement === pace)
        XCTAssertNotNil(replacement.pace)
        XCTAssertTrue(replacement.isMenuTracking)
        XCTAssertNotNil(controller.quotaPaceTimerForTesting)
    }

    func testPredictionRestorationGuardSurvivesClosedMenuAndRecoversOnNewDeadline() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(9_000)
        let controller = makeController()
        defer { controller.teardown() }
        controller.quotaPaceNowForTesting = now
        controller.start(snapshot: timedPaceSnapshot(now: now, remaining: 40, resetAt: reset), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        func currentPace() throws -> QuotaProgressPaceView {
            try XCTUnwrap((controller.menuItemsForTesting.first?.view as? MenuHoverLinkHostView)?.paceViews.first)
        }
        XCTAssertNotNil(try currentPace().prediction)
        controller.menuWillOpen(controller.statusMenuForTesting)
        controller.menuDidClose(controller.statusMenuForTesting)
        controller.update(snapshot: timedPaceSnapshot(now: now, remaining: 60, resetAt: reset), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        controller.menuWillOpen(controller.statusMenuForTesting)
        XCTAssertNotNil(try currentPace().pace)
        XCTAssertNil(try currentPace().prediction)
        XCTAssertNotNil(try currentPace().tooltipContent?.body)
        controller.update(snapshot: .error("Temporary quota failure"), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        XCTAssertNil(try currentPace().prediction)
        controller.update(snapshot: timedPaceSnapshot(now: now, remaining: 55, resetAt: reset), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        XCTAssertNil(try currentPace().prediction)
        controller.menuDidClose(controller.statusMenuForTesting)
        controller.update(snapshot: timedPaceSnapshot(now: now, remaining: 80, resetAt: now.addingTimeInterval(12_000)), refreshDate: now,
            menuInput: makeMenuInput(), settings: makeSettings())
        controller.menuWillOpen(controller.statusMenuForTesting)
        XCTAssertNotNil(try currentPace().prediction)
        controller.update(snapshot: timedPaceSnapshot(now: now, remaining: 50), refreshDate: now,
            menuInput: makeMenuInput(activeClient: .claude), settings: makeSettings())
        XCTAssertNil(try currentPace().prediction, "Five-hour semantics were only checked for Codex")
    }

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
        XCTAssertEqual(
            balanceLayout.amount,
            CGRect(
                x: OpenCodexCardLayout.amountX,
                y: 10,
                width: OpenCodexCardLayout.amountWidth,
                height: 48
            )
        )
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
        XCTAssertFalse(amountViews(in: officialOverview).contains {
            $0.identifier?.rawValue == "codex.bankedReset.probability24h"
        })
        XCTAssertFalse(amountViews(in: officialOverview).contains {
            $0.identifier?.rawValue == "codex.bankedReset.probability48h"
        })
        let subtitle = try XCTUnwrap(descendantViews(of: officialOverview, as: AccountMarqueeView.self).first {
            $0.identifier?.rawValue == "codex.bankedReset.forecastSubtitle"
        })
        XCTAssertEqual(subtitle.accountLabel.stringValue, tr(.keyCodexBankedResetProbability48hFormat, arguments: ["42%"]))
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
            openAIAccount: OpenAIAccountPresentation(email: "pace@example.com"),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false
        )
    }

    private func makeSettings(timeZone: TimeZone = .autoupdatingCurrent) -> StatusItemController.MenuBarSettings {
        StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true,
            displayTimeZone: timeZone
        )
    }
}

extension OverviewNumericTransitionTests {
    func testAggregationSameNameSameBalanceHasSeparateProviderAndAccountIdentity() {
        let snapshot = Snapshot.balance("tokenshop", 4.73, "USD", nil, Date(), progressPercentage: nil)
        func samples(_ scope: String) -> [OverviewNumericSample] {
            OverviewNumericPresentation.samples(snapshot: snapshot, providerIdentity: scope,
                lunaReserveDisplayMode: .defaultValue, hideExhaustedQuota: false, showBankedReset: true)
        }
        let a = samples("codex|grok|account-a")
        let b = samples("codex|gpt|account-b")
        XCTAssertNotEqual(a.first?.identity, b.first?.identity)
        XCTAssertEqual(OverviewNumericTransition.commitSeenValues(a + b).count, 2)
        XCTAssertFalse(OverviewNumericTransition.plan(previous: a.first, current: b[0], reduceMotion: false).animates)
        XCTAssertNotEqual(samples("codex|grok|new-account").first?.identity, a.first?.identity)
    }
}


extension OverviewNumericTransitionTests {
    func testCurrencySymbolUsesSmallerMediumFontWhileDigitsRetainQuotaFont() {
        let digits = NSFont.monospacedDigitSystemFont(ofSize: OpenCodexCardLayout.quotaAmountPointSize, weight: .semibold)
        let symbol = OverviewNumericTextView.currencySymbolFont(for: digits)
        XCTAssertEqual(symbol.pointSize, 31 * 0.65, accuracy: 0.01)
        XCTAssertEqual(digits.pointSize, 31)
        XCTAssertNotEqual(symbol.fontName, digits.fontName)
    }
}
