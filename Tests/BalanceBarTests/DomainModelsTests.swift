import Foundation
import XCTest
@testable import BalanceBar

final class DomainModelsTests: XCTestCase {
    func testAssistantClientAndStatusLinkValueModels() throws {
        XCTAssertEqual(AssistantClient.codex.appType, "codex")
        XCTAssertEqual(AssistantClient.codex.displayName, "Codex")
        XCTAssertEqual(AssistantClient.claude.appType, "claude")
        XCTAssertEqual(AssistantClient.claude.displayName, "Claude Code")

        let link = StatusLink(title: "Status", url: "https://status.example")
        XCTAssertEqual(link, StatusLink(title: "Status", url: "https://status.example"))
        let encoded = try JSONEncoder().encode(link)
        XCTAssertEqual(try JSONDecoder().decode(StatusLink.self, from: encoded), link)
    }

    func testOpenAIAccountPresentationUsesOnlyTheCurrentOfficialCodexProvider() {
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

        XCTAssertNil(
            OpenAIAccountPresentation.current(
                activeClient: .claude,
                providerIsOfficial: true,
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
            1 / 4.01 * 100,
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
        XCTAssertEqual(try progress(store, amount: -1.02, unit: "USD", identity: identity), 1)

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
        guard case .failure(.inconsistentUnit(expected: "USD", actual: "CNY")) = store.update(
            amount: 9,
            unit: "CNY",
            identity: invalidIdentity
        ) else {
            return XCTFail("unit changes must not update the baseline")
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

    func testOpenCodexCardPresentationDoesNotExposeModelIdentity() {
        let date = Date(timeIntervalSince1970: 1_700_000_123)
        let currentOfficial = OpenCodexModelCard(
            selector: "gpt-5.6-luna",
            provider: "openai",
            model: "gpt-5.6-luna",
            isCurrent: true,
            data: .official(
                remaining: 81.7,
                label: "7-Day Quota",
                reset: "2 hours",
                updatedAt: date
            )
        )

        let official = OpenCodexCardPresentation.menuBarSnapshot(
            for: currentOfficial
        )
        XCTAssertEqual(official.menuBarPrimary, "81%")
        XCTAssertEqual(official.menuBarSecondary, "2 hours")
        XCTAssertFalse(official.menuBarTitle.contains("gpt-5.6-luna"))
        XCTAssertFalse(official.menuBarToolTip.contains("gpt-5.6-luna"))

        let preciseWindow = OfficialQuotaWindow(
            kind: .sevenDay,
            remaining: 81.7,
            label: "7-Day Quota",
            daysText: "7 Days",
            reset: "2 hours",
            durationSeconds: 604_800,
            resetAt: date.addingTimeInterval(7_200)
        )
        let preciseCard = OpenCodexModelCard(
            selector: "gpt-5.6-luna",
            provider: "openai",
            model: "gpt-5.6-luna",
            isCurrent: true,
            data: .official(window: preciseWindow, updatedAt: date)
        )
        let preciseSnapshot = OpenCodexCardPresentation.menuBarSnapshot(for: preciseCard)
        XCTAssertEqual(preciseSnapshot.officialQuotaWindows, [preciseWindow])
        XCTAssertEqual(
            preciseSnapshot.officialResetDisplayValue(
                now: date,
                calendar: Calendar(identifier: .gregorian),
                locale: Locale(identifier: "en_GB"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            preciseWindow.resetDisplayText(
                now: date,
                calendar: Calendar(identifier: .gregorian),
                locale: Locale(identifier: "en_GB"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        )

        let currentBalance = OpenCodexModelCard(
            selector: "relay/gpt-5.6-sol",
            provider: "relay",
            model: "gpt-5.6-sol",
            isCurrent: true,
            data: .balance(
                amount: 12.34,
                unit: "USD",
                progressPercentage: 64.2,
                websiteURL: URL(string: "https://relay.example.test"),
                updatedAt: date
            )
        )
        let balance = OpenCodexCardPresentation.menuBarSnapshot(for: currentBalance)
        XCTAssertEqual(balance.menuBarPrimary, "$12.34")
        XCTAssertEqual(balance.menuBarSecondary, "")
        XCTAssertEqual(balance.progressPercentage, 64.2)
        XCTAssertFalse(balance.menuBarTitle.contains("gpt-5.6-sol"))

        let loading = OpenCodexCardPresentation.menuBarSnapshot(
            for: OpenCodexModelCard(
                selector: "relay/secret-model",
                provider: "relay",
                model: "secret-model",
                isCurrent: true,
                data: .loading(category: .balance)
            )
        )
        XCTAssertEqual(loading.menuBarPrimary, "…")
        XCTAssertFalse(loading.menuBarTitle.contains("secret-model"))

        let unavailable = OpenCodexCardPresentation.menuBarSnapshot(
            for: OpenCodexModelCard(
                selector: "relay/secret-model",
                provider: "relay",
                model: "secret-model",
                isCurrent: true,
                data: .unavailable(
                    category: .balance,
                    reason: "Balance unavailable"
                )
            )
        )
        XCTAssertEqual(unavailable.menuBarPrimary, "!")
        XCTAssertFalse(unavailable.menuBarTitle.contains("secret-model"))
    }

    func testOpenCodexMenuBarAlwaysUsesFirstPreferenceInPublishedOrder() {
        let date = Date(timeIntervalSince1970: 1_700_000_456)
        let baseSnapshot = Snapshot.openCodex(
            "OpenCodex",
            selector: "tokenshop/gpt-5.6-sol",
            status: "Connected",
            date
        )

        let firstLoading = OpenCodexModelCard(
            selector: "openai/gpt-5.6-sol",
            provider: "openai",
            model: "gpt-5.6-sol",
            isCurrent: false,
            data: .loading(category: .quota)
        )
        let laterOfficial = OpenCodexModelCard(
            selector: "openai/gpt-5.6-luna",
            provider: "openai",
            model: "gpt-5.6-luna",
            isCurrent: false,
            data: .official(
                remaining: 77.4,
                label: "7-Day Quota",
                reset: "6d18h",
                updatedAt: date
            )
        )
        let laterBalance = OpenCodexModelCard(
            selector: "tokenshop/gpt-5.6-sol",
            provider: "tokenshop",
            model: "gpt-5.6-sol",
            isCurrent: true,
            data: .balance(
                amount: 1.44,
                unit: "USD",
                progressPercentage: 28.8,
                websiteURL: URL(string: "https://tokenshop.homes"),
                updatedAt: date
            )
        )
        var publishedCards = [firstLoading, laterOfficial, laterBalance]

        let initialMatch = OpenCodexCardPresentation.menuBarCardMatch(from: publishedCards)
        XCTAssertEqual(initialMatch.diagnosticReason, "first-preference")
        XCTAssertEqual(initialMatch.card?.selector, "openai/gpt-5.6-sol")
        let loading = OpenCodexCardPresentation.menuBarSnapshot(
            for: baseSnapshot,
            cards: publishedCards
        )
        XCTAssertEqual(loading.menuBarPrimary, "…")
        XCTAssertEqual(loading.menuBarSecondary, "")

        publishedCards[0] = OpenCodexModelCard(
            selector: "openai/gpt-5.6-sol",
            provider: "openai",
            model: "gpt-5.6-sol",
            isCurrent: false,
            data: .official(
                remaining: 77.4,
                label: "7-Day Quota",
                reset: "6d18h",
                updatedAt: date
            )
        )
        let official = OpenCodexCardPresentation.menuBarSnapshot(
            for: baseSnapshot,
            cards: publishedCards
        )
        XCTAssertEqual(official.menuBarPrimary, "77%")
        XCTAssertEqual(official.menuBarSecondary, "6d18h")
        XCTAssertFalse(official.menuBarTitle.contains("gpt-5.6-sol"))

        let publishedMatch = OpenCodexCardPresentation.menuBarCardMatch(from: publishedCards)
        XCTAssertEqual(publishedMatch.diagnosticReason, "first-preference")
        XCTAssertEqual(publishedMatch.card?.selector, "openai/gpt-5.6-sol")

        publishedCards[0] = OpenCodexModelCard(
            selector: "openai/gpt-5.6-sol",
            provider: "openai",
            model: "gpt-5.6-sol",
            isCurrent: false,
            data: .unavailable(
                category: .quota,
                reason: "Quota unavailable"
            )
        )
        let unavailable = OpenCodexCardPresentation.menuBarSnapshot(
            for: baseSnapshot,
            cards: publishedCards
        )
        XCTAssertEqual(unavailable.menuBarPrimary, "!")
        XCTAssertFalse(unavailable.menuBarTitle.contains("gpt-5.6-sol"))

        publishedCards = [laterBalance, publishedCards[0], laterOfficial]
        let reordered = OpenCodexCardPresentation.menuBarSnapshot(
            for: baseSnapshot,
            cards: publishedCards
        )
        XCTAssertEqual(reordered.menuBarPrimary, "$1.44")
        XCTAssertEqual(reordered.menuBarSecondary, "")
        XCTAssertFalse(reordered.menuBarTitle.contains("gpt-5.6-sol"))
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
