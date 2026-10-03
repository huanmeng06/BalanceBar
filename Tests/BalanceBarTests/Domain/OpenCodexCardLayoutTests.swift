import AppKit
import XCTest
@testable import BalanceBar

final class OpenCodexCardLayoutTests: XCTestCase {
    func testOpenCodexCardLayoutMatchesExistingOfficialAndBalanceOverviewFrames() {
        let official = OpenCodexCardLayout.frames(for: .quota)
        XCTAssertEqual(official.cardSize, CGSize(width: 304, height: 94))
        XCTAssertEqual(official.title, CGRect(x: 14, y: 67, width: 189, height: 20))
        XCTAssertEqual(official.refreshTime, CGRect(x: 209, y: 68, width: 81, height: 17))
        XCTAssertNil(official.account)
        XCTAssertNil(official.subscription)
        XCTAssertEqual(official.quotaDetail, CGRect(x: 14, y: 39, width: 128, height: 18))
        XCTAssertEqual(official.reset, CGRect(x: 14, y: 20, width: 128, height: 17))
        XCTAssertEqual(official.amount, CGRect(x: 149, y: 10, width: 141, height: 48))
        XCTAssertEqual(official.progress, CGRect(x: 14, y: 8, width: 276, height: 5))
        XCTAssertEqual(
            official.reset!.minY - official.progress!.maxY,
            OpenCodexCardLayout.quotaProgressTopGap,
            accuracy: 0.001
        )
        XCTAssertNil(official.linkPrefix)
        XCTAssertNil(official.link)

        let balance = OpenCodexCardLayout.frames(for: .balance, linkPrefixWidth: 62)
        XCTAssertEqual(balance.cardSize, CGSize(width: 304, height: 94))
        XCTAssertEqual(balance.title, CGRect(x: 14, y: 67, width: 189, height: 20))
        XCTAssertEqual(balance.refreshTime, CGRect(x: 209, y: 68, width: 81, height: 17))
        XCTAssertNil(balance.account)
        XCTAssertNil(balance.subscription)
        XCTAssertEqual(balance.quotaDetail, CGRect(x: 14, y: 39, width: 128, height: 18))
        XCTAssertNil(balance.reset)
        XCTAssertEqual(balance.amount, CGRect(x: 149, y: 10, width: 141, height: 48))
        XCTAssertEqual(balance.progress, CGRect(x: 14, y: 8, width: 276, height: 5))
        XCTAssertEqual(balance.linkPrefix, CGRect(x: 14, y: 20, width: 62, height: 17))
        XCTAssertEqual(balance.link, CGRect(x: 75, y: 20, width: 148, height: 17))
        XCTAssertEqual(
            balance.link!.minY - balance.progress!.maxY,
            OpenCodexCardLayout.quotaProgressTopGap,
            accuracy: 0.001
        )

        let englishBalance = OpenCodexCardLayout.frames(for: .balance, linkPrefixWidth: 72)
        XCTAssertEqual(englishBalance.linkPrefix, CGRect(x: 14, y: 20, width: 72, height: 17))
        XCTAssertEqual(englishBalance.link, CGRect(x: 85, y: 20, width: 136, height: 17))
    }

    func testOpenCodexCardLayoutCollapsesProgressSlotWhenQuotaProgressIsHidden() {
        let shift = OpenCodexCardLayout.quotaRowHeight - OpenCodexCardLayout.lunaReserveNoProgressRowHeight
        let official = OpenCodexCardLayout.frames(for: .quota, includesQuotaProgress: false)
        XCTAssertEqual(official.cardSize, CGSize(width: 304, height: 102 - shift))
        XCTAssertNil(official.progress)
        XCTAssertEqual(official.amount.height, OpenCodexCardLayout.lunaReserveNoProgressAmountHeight)

        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: "5-hour",
                daysText: "5 hours",
                reset: "2h",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: "7-day",
                daysText: "7 days",
                reset: "7d",
                durationSeconds: 604_800
            )
        ]
        let expanded = OpenCodexCardLayout.frames(
            for: .quota,
            officialQuotaWindows: windows,
            includesQuotaProgress: false
        )
        XCTAssertEqual(expanded.quotaRows.count, 2)
        XCTAssertTrue(expanded.quotaRows.allSatisfy { $0.progress == .zero })
        XCTAssertTrue(
            expanded.quotaRows.allSatisfy {
                $0.amount.height == OpenCodexCardLayout.bankedResetTextBandAmountHeight
                    && abs($0.amount.minY - $0.reset.minY) < 0.001
                    && abs($0.amount.maxY - $0.quotaDetail.maxY) < 0.001
            }
        )
        let withProgress = OpenCodexCardLayout.frames(
            for: .quota,
            officialQuotaWindows: windows,
            includesQuotaProgress: true
        )
        XCTAssertLessThan(expanded.cardSize.height + 8, withProgress.cardSize.height)

        let balance = OpenCodexCardLayout.frames(for: .balance, includesQuotaProgress: false)
        XCTAssertEqual(balance.cardSize, CGSize(width: 304, height: 102 - shift))
        XCTAssertNil(balance.progress)
        XCTAssertEqual(balance.linkPrefix?.minY, 28 - shift)
        XCTAssertEqual(balance.link?.minY, 28 - shift)
        XCTAssertEqual(balance.quotaDetail, CGRect(x: 14, y: 29, width: 128, height: 18))
        XCTAssertEqual(balance.amount, CGRect(x: 149, y: 0, width: 141, height: 48))
        XCTAssertEqual(balance.amount.height, 48)
        XCTAssertEqual(balance.amount.maxY, balance.quotaDetail.maxY + 1)
        XCTAssertEqual(official.amount.height, OpenCodexCardLayout.lunaReserveNoProgressAmountHeight)
    }

    func testOfficialQuotaLayoutKeepsBankedResetCompactGapWhenQuotaProgressIsHidden() throws {
        let windows = [
            OfficialQuotaWindow(kind: .fiveHour, remaining: 80, label: "5-hour", daysText: "5 hours", reset: "5h", durationSeconds: 18_000),
            OfficialQuotaWindow(kind: .sevenDay, remaining: 45, label: "7-day", daysText: "7 days", reset: "7d", durationSeconds: 604_800)
        ]
        let frames = OpenCodexCardLayout.frames(for: .quota, officialQuotaWindows: windows, includesQuotaProgress: false, includesBankedReset: true, bankedResetCardCount: 1)
        let probability = try XCTUnwrap(frames.bankedResetProbabilityRow)
        let summary = try XCTUnwrap(frames.bankedResetSummaryRow)
        let metrics = try XCTUnwrap(frames.bankedResetForecastMetrics)
        XCTAssertEqual(probability.amount.minY, probability.reset.minY, accuracy: 0.001)
        XCTAssertEqual(metrics.minY, probability.reset.minY, accuracy: 0.001)
        XCTAssertEqual(metrics.minY - summary.quotaDetail.maxY, OpenCodexCardLayout.quotaVisibleBlockGap, accuracy: 0.001)
    }
    func testBankedResetProbabilityKeepsForecastMetricsSlotForOfficialHint() throws {
        let windows = [
            OfficialQuotaWindow(kind: .fiveHour, remaining: 80, label: "5-hour", daysText: "5 hours", reset: "5h", durationSeconds: 18_000),
            OfficialQuotaWindow(kind: .sevenDay, remaining: 45, label: "7-day", daysText: "7 days", reset: "7d", durationSeconds: 604_800)
        ]
        let frames = OpenCodexCardLayout.frames(for: .quota, officialQuotaWindows: windows, includesBankedReset: true, bankedResetCardCount: 1)
        let probability = try XCTUnwrap(frames.bankedResetProbabilityRow)
        let metrics = try XCTUnwrap(frames.bankedResetForecastMetrics)
        XCTAssertEqual(metrics.origin, probability.reset.origin)
        XCTAssertEqual(metrics.width, probability.reset.width, accuracy: 0.001)
        XCTAssertEqual(probability.amount.minY, probability.reset.minY, accuracy: 0.001)
    }
    func testBankedResetProbabilityAndSummaryAmountSpansTitleAndSubtitleBand() throws {
        let windows = [
            OfficialQuotaWindow(kind: .fiveHour, remaining: 80, label: "5-hour", daysText: "5 hours", reset: "5h", durationSeconds: 18_000),
            OfficialQuotaWindow(kind: .sevenDay, remaining: 45, label: "7-day", daysText: "7 days", reset: "7d", durationSeconds: 604_800)
        ]
        let frames = OpenCodexCardLayout.frames(for: .quota, officialQuotaWindows: windows, includesBankedReset: true, bankedResetCardCount: 1)
        let probability = try XCTUnwrap(frames.bankedResetProbabilityRow)
        let summary = try XCTUnwrap(frames.bankedResetSummaryRow)
        XCTAssertEqual(probability.amount.height, OpenCodexCardLayout.bankedResetTextBandAmountHeight, accuracy: 0.001)
        XCTAssertEqual(summary.amount.height, OpenCodexCardLayout.bankedResetTextBandAmountHeight, accuracy: 0.001)
        XCTAssertEqual(probability.amount.maxY, probability.quotaDetail.maxY, accuracy: 0.001)
        XCTAssertEqual(probability.reset.width, 128, accuracy: 0.001)
    }
    func testOpenAIAccountRowAddsASeparatedSubtitleBeforeQuotaDetails() {
        let frames = OpenCodexCardLayout.frames(for: .quota, includesAccount: true)

        XCTAssertEqual(frames.cardSize, CGSize(width: 304, height: 113))
        XCTAssertEqual(frames.title, CGRect(x: 14, y: 86, width: 189, height: 20))
        XCTAssertEqual(frames.refreshTime, CGRect(x: 209, y: 87, width: 81, height: 17))
        XCTAssertEqual(frames.account, CGRect(x: 14, y: 67, width: 276, height: 17))
        XCTAssertNil(frames.subscription)
        XCTAssertEqual(frames.quotaDetail, CGRect(x: 14, y: 39, width: 128, height: 18))
        XCTAssertEqual(frames.reset, CGRect(x: 14, y: 20, width: 128, height: 17))
        XCTAssertEqual(frames.amount, CGRect(x: 149, y: 10, width: 141, height: 48))
        XCTAssertEqual(frames.progress, CGRect(x: 14, y: 8, width: 276, height: 5))

        XCTAssertLessThan(frames.quotaDetail.maxY, frames.account?.minY ?? 0)
        XCTAssertLessThan(frames.progress?.maxY ?? 0, frames.reset?.minY ?? 0)
    }

    func testOpenAISubscriptionTextSharesAccountRowAndReservesRightAlignedSpace() {
        let renderedSubscriptionTextWidth: CGFloat = 34
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            subscriptionTextWidth: renderedSubscriptionTextWidth
        )

        XCTAssertEqual(frames.cardSize, CGSize(width: 304, height: 113))
        XCTAssertEqual(frames.account, CGRect(x: 14, y: 67, width: 234, height: 17))
        XCTAssertEqual(frames.subscription, CGRect(x: 212, y: 67, width: 78, height: 17))
        XCTAssertEqual(frames.title, CGRect(x: 14, y: 86, width: 189, height: 20))
        XCTAssertEqual(frames.refreshTime, CGRect(x: 209, y: 87, width: 81, height: 17))
        XCTAssertEqual(frames.account?.minY, frames.subscription?.minY)
        XCTAssertEqual(frames.account?.height, frames.subscription?.height)
        XCTAssertEqual(
            frames.account?.maxX ?? 0,
            (frames.subscription?.maxX ?? 0)
                - renderedSubscriptionTextWidth
                - OpenCodexCardLayout.subscriptionTextSafetyGap,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(frames.account?.maxX ?? 0, frames.subscription?.minX ?? 0)
        XCTAssertLessThanOrEqual(frames.subscription?.maxX ?? 0, frames.cardSize.width - 14)

        let errorFrames = ErrorCardLayout.errorFrames(
            for: "quota unavailable",
            includesAccount: true,
            includesSubscription: true,
            subscriptionTextWidth: renderedSubscriptionTextWidth
        )
        XCTAssertEqual(errorFrames.account, CGRect(x: 14, y: 58, width: 234, height: 17))
        XCTAssertEqual(errorFrames.subscription, CGRect(x: 212, y: 58, width: 78, height: 17))
        XCTAssertEqual(errorFrames.account?.minY, errorFrames.subscription?.minY)
        XCTAssertEqual(errorFrames.account?.height, errorFrames.subscription?.height)
        XCTAssertEqual(
            errorFrames.account?.maxX ?? 0,
            (errorFrames.subscription?.maxX ?? 0)
                - renderedSubscriptionTextWidth
                - OpenCodexCardLayout.subscriptionTextSafetyGap,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            errorFrames.account?.maxX ?? 0,
            errorFrames.subscription?.minX ?? 0
        )
    }

    func testOfficialQuotaLayoutExpandsForOrderedFiveHourAndSevenDayRows() {
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: "5-Hour Quota",
                daysText: "5 Hours",
                reset: "1h0m",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: "7-Day Quota",
                daysText: "7 Days",
                reset: "1h30m",
                durationSeconds: 604_800
            )
        ]
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows
        )

        XCTAssertEqual(frames.cardSize, CGSize(width: 304, height: 183))
        XCTAssertEqual(frames.quotaRows.count, 2)
        XCTAssertEqual(frames.account, CGRect(x: 14, y: 137, width: 198, height: 17))
        XCTAssertEqual(frames.subscription, CGRect(x: 212, y: 137, width: 78, height: 17))
        XCTAssertEqual(frames.title, CGRect(x: 14, y: 156, width: 189, height: 20))
        XCTAssertEqual(frames.refreshTime, CGRect(x: 209, y: 157, width: 81, height: 17))

        let fiveHour = frames.quotaRows[0]
        let sevenDay = frames.quotaRows[1]
        XCTAssertGreaterThan(fiveHour.progress.minY, sevenDay.progress.minY)
        XCTAssertEqual(
            fiveHour.progress.minY - (sevenDay.progress.minY + OpenCodexCardLayout.quotaProgressRowHeight),
            OpenCodexCardLayout.quotaRowGap,
            accuracy: 0.001
        )
        XCTAssertEqual(fiveHour.progress.width, 276)
        XCTAssertEqual(sevenDay.progress.width, 276)
        let baseline = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true
        )
        XCTAssertGreaterThan(frames.cardSize.height, baseline.cardSize.height)
        for row in frames.quotaRows {
            XCTAssertEqual(row.amount.width, baseline.amount.width)
            XCTAssertEqual(
                row.amount.height,
                OpenCodexCardLayout.bankedResetTextBandAmountHeight,
                accuracy: 0.001
            )
            XCTAssertEqual(row.amount.minY, row.reset.minY, accuracy: 0.001)
            XCTAssertEqual(row.amount.maxY, row.quotaDetail.maxY, accuracy: 0.001)
            XCTAssertEqual(row.quotaDetail.width, baseline.quotaDetail.width)
            XCTAssertEqual(row.quotaDetail.height, baseline.quotaDetail.height)
            XCTAssertEqual(row.reset.width, baseline.reset?.width ?? 0)
            XCTAssertEqual(row.reset.height, baseline.reset?.height ?? 0)
            XCTAssertEqual(row.progress.width, baseline.progress?.width ?? 0)
            XCTAssertEqual(row.progress.height, baseline.progress?.height ?? 0)
            XCTAssertGreaterThanOrEqual(row.quotaDetail.minY, 0)
            XCTAssertLessThanOrEqual(row.quotaDetail.maxY, frames.cardSize.height)
            XCTAssertGreaterThanOrEqual(row.reset.minY, 0)
            XCTAssertLessThanOrEqual(row.reset.maxY, frames.cardSize.height)
        }
        XCTAssertLessThanOrEqual(sevenDay.progress.maxY, sevenDay.reset.minY)
        XCTAssertLessThanOrEqual(sevenDay.reset.maxY, sevenDay.quotaDetail.minY)
        XCTAssertLessThanOrEqual(fiveHour.progress.maxY, fiveHour.reset.minY)
        XCTAssertLessThanOrEqual(fiveHour.reset.maxY, fiveHour.quotaDetail.minY)
        XCTAssertLessThanOrEqual(fiveHour.quotaDetail.maxY, frames.account?.minY ?? 0)
        for row in frames.quotaRows {
            XCTAssertGreaterThanOrEqual(row.progress.minX, 14)
            XCTAssertLessThanOrEqual(row.progress.maxX, frames.cardSize.width - 14)
            XCTAssertGreaterThanOrEqual(row.amount.minY, 0)
            XCTAssertLessThanOrEqual(row.amount.maxY, frames.cardSize.height)
        }
    }

    func testOfficialQuotaLayoutPlacesReserveBetweenFiveHourAndSevenDayRows() {
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: "5-Hour Quota",
                daysText: "5 Hours",
                reset: "1h0m",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: "7-Day Quota",
                daysText: "7 Days",
                reset: "1h30m",
                durationSeconds: 604_800
            )
        ]
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesLunaReserve: true
        )

        XCTAssertEqual(frames.quotaRows.count, 2)
        XCTAssertNotNil(frames.lunaReserveRow)
        XCTAssertEqual(frames.cardSize.height, 249)
        XCTAssertEqual(
            frames.lunaReserveRow?.progress.minY,
            OpenCodexCardLayout.quotaBottomInset
                + OpenCodexCardLayout.quotaProgressRowHeight
                + OpenCodexCardLayout.quotaRowGap
        )
        XCTAssertEqual(
            frames.quotaRows[1].progress.minY,
            OpenCodexCardLayout.quotaBottomInset
        )
        XCTAssertEqual(
            frames.quotaRows[0].progress.minY,
            frames.lunaReserveRow!.progress.minY
                + OpenCodexCardLayout.quotaProgressRowHeight
                + OpenCodexCardLayout.quotaRowGap
        )
        XCTAssertEqual(
            frames.lunaReserveRow!.reset.minY - frames.lunaReserveRow!.progress.maxY,
            OpenCodexCardLayout.quotaProgressTopGap,
            accuracy: 0.001
        )

        let unavailableFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesLunaReserve: true,
            includesLunaReserveProgress: false
        )
        XCTAssertEqual(unavailableFrames.cardSize.height, 239)
        XCTAssertEqual(unavailableFrames.lunaReserveRow?.progress ?? .zero, .zero)
        XCTAssertEqual(
            unavailableFrames.lunaReserveRow?.amount.height,
            OpenCodexCardLayout.lunaReserveNoProgressAmountHeight
        )
        XCTAssertEqual(
            unavailableFrames.quotaRows[1].progress.minY,
            OpenCodexCardLayout.quotaBottomInset
        )
        XCTAssertEqual(
            unavailableFrames.lunaReserveRow?.amount.minY,
            OpenCodexCardLayout.quotaBottomInset
                + OpenCodexCardLayout.quotaProgressRowHeight
                + OpenCodexCardLayout.quotaRowGap
        )
        XCTAssertEqual(
            unavailableFrames.quotaRows[0].progress.minY,
            unavailableFrames.lunaReserveRow!.amount.minY
                + OpenCodexCardLayout.lunaReserveNoProgressRowHeight
                + OpenCodexCardLayout.quotaRowGap
        )
        XCTAssertLessThan(unavailableFrames.cardSize.height, frames.cardSize.height)
    }

    func testOfficialQuotaLayoutHonorsReserveInsertionIndexWithOneStableRow() {
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 0,
                label: "5-Hour Quota",
                daysText: "5 Hours",
                reset: "1h0m",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 0,
                label: "7-Day Quota",
                daysText: "7 Days",
                reset: "1h30m",
                durationSeconds: 604_800
            )
        ]

        func frames(insertionIndex: Int, includesProgress: Bool = true) -> OpenCodexCardFrames {
            OpenCodexCardLayout.frames(
                for: .quota,
                officialQuotaWindows: windows,
                includesLunaReserve: true,
                includesLunaReserveProgress: includesProgress,
                lunaReserveInsertionIndex: insertionIndex
            )
        }

        let beforeFiveHour = frames(insertionIndex: 0)
        let afterFiveHour = frames(insertionIndex: 1)
        let afterSevenDay = frames(insertionIndex: 2)

        for layout in [beforeFiveHour, afterFiveHour, afterSevenDay] {
            XCTAssertEqual(layout.quotaRows.count, 2)
            XCTAssertNotNil(layout.lunaReserveRow)
        }
        XCTAssertGreaterThan(
            beforeFiveHour.lunaReserveRow!.progress.minY,
            beforeFiveHour.quotaRows[0].progress.minY
        )
        XCTAssertGreaterThan(
            beforeFiveHour.quotaRows[0].progress.minY,
            beforeFiveHour.quotaRows[1].progress.minY
        )
        XCTAssertGreaterThan(
            afterFiveHour.quotaRows[0].progress.minY,
            afterFiveHour.lunaReserveRow!.progress.minY
        )
        XCTAssertGreaterThan(
            afterFiveHour.lunaReserveRow!.progress.minY,
            afterFiveHour.quotaRows[1].progress.minY
        )
        XCTAssertGreaterThan(
            afterSevenDay.quotaRows[0].progress.minY,
            afterSevenDay.quotaRows[1].progress.minY
        )
        XCTAssertGreaterThan(
            afterSevenDay.quotaRows[1].progress.minY,
            afterSevenDay.lunaReserveRow!.progress.minY
        )

        let unavailableAfterSevenDay = frames(insertionIndex: 2, includesProgress: false)
        XCTAssertEqual(unavailableAfterSevenDay.quotaRows.count, 2)
        XCTAssertNotNil(unavailableAfterSevenDay.lunaReserveRow)
        XCTAssertGreaterThan(
            unavailableAfterSevenDay.quotaRows[1].progress.minY,
            unavailableAfterSevenDay.lunaReserveRow!.amount.minY
        )
    }

    func testOfficialQuotaLayoutPlacesBankedResetBlockBelowQuotaRowsWithoutProgress() throws {
        let windows = [
            OfficialQuotaWindow(kind: .fiveHour, remaining: 80, label: "5-hour", daysText: "5 hours", reset: "5h", durationSeconds: 18_000),
            OfficialQuotaWindow(kind: .sevenDay, remaining: 45, label: "7-day", daysText: "7 days", reset: "7d", durationSeconds: 604_800)
        ]
        let frames = OpenCodexCardLayout.frames(for: .quota, officialQuotaWindows: windows, includesQuotaProgress: false, includesBankedReset: true, bankedResetCardCount: 2)
        let probability = try XCTUnwrap(frames.bankedResetProbabilityRow)
        let summary = try XCTUnwrap(frames.bankedResetSummaryRow)
        XCTAssertEqual(probability.reset.minY - summary.quotaDetail.maxY, OpenCodexCardLayout.quotaVisibleBlockGap, accuracy: 0.001)
        XCTAssertEqual(frames.quotaRows.count, 2)
    }
    func testOfficialQuotaLayoutClipsDetailedBankedResetTicketsToTwoAndAHalfRows() throws {
        let windows = [
            OfficialQuotaWindow(kind: .fiveHour, remaining: 80, label: "5-hour", daysText: "5 hours", reset: "5h", durationSeconds: 18_000),
            OfficialQuotaWindow(kind: .sevenDay, remaining: 45, label: "7-day", daysText: "7 days", reset: "7d", durationSeconds: 604_800)
        ]
        let frames = OpenCodexCardLayout.frames(for: .quota, officialQuotaWindows: windows, includesBankedReset: true, bankedResetCardCount: 10, bankedResetDisplayMode: .detailed)
        XCTAssertEqual(frames.bankedResetDetailRows.count, 10)
        XCTAssertLessThanOrEqual(frames.bankedResetTicketViewport?.height ?? 0, OpenCodexCardLayout.bankedResetTicketViewportMaxHeight)
        XCTAssertEqual(frames.bankedResetSummaryRow?.amount.height, OpenCodexCardLayout.bankedResetTextBandAmountHeight)
    }
    func testQuickSwitchMenuEntriesContainOnlyCCSwitchProviderChoices() {
        let choices = [
            ProviderChoice(id: "opencodex", name: "OpenCodex", isCurrent: true),
            ProviderChoice(id: "ordinary", name: "Ordinary", isCurrent: false)
        ]

        XCTAssertEqual(
            QuickSwitchMenuModel.entries(from: choices),
            [
                QuickSwitchMenuEntry(id: "opencodex", name: "OpenCodex", isCurrent: true),
                QuickSwitchMenuEntry(id: "ordinary", name: "Ordinary", isCurrent: false)
            ]
        )
    }

    func testBalanceRefreshReasonStillForcesOrdinaryProviderBalanceExceptScheduled() {
        XCTAssertTrue(BalanceRefreshReason.activityUsage.forcesStandardProviderBalance)
        XCTAssertTrue(BalanceRefreshReason.initial.forcesStandardProviderBalance)
        XCTAssertTrue(BalanceRefreshReason.manual.forcesStandardProviderBalance)
        XCTAssertTrue(BalanceRefreshReason.providerChanged.forcesStandardProviderBalance)
        XCTAssertTrue(BalanceRefreshReason.configurationChanged.forcesStandardProviderBalance)
        XCTAssertTrue(BalanceRefreshReason.clientChanged.forcesStandardProviderBalance)
        XCTAssertFalse(BalanceRefreshReason.scheduled.forcesStandardProviderBalance)
    }
}
