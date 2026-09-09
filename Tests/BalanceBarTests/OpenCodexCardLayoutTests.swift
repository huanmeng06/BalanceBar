import XCTest
@testable import BalanceBar

final class OpenCodexCardLayoutTests: XCTestCase {
    func testOpenCodexCardLayoutMatchesExistingOfficialAndBalanceOverviewFrames() {
        let official = OpenCodexCardLayout.frames(for: .quota)
        XCTAssertEqual(official.cardSize, CGSize(width: 304, height: 102))
        XCTAssertEqual(official.title, CGRect(x: 14, y: 75, width: 189, height: 20))
        XCTAssertEqual(official.refreshTime, CGRect(x: 209, y: 76, width: 81, height: 17))
        XCTAssertNil(official.account)
        XCTAssertNil(official.subscription)
        XCTAssertEqual(official.quotaDetail, CGRect(x: 14, y: 47, width: 128, height: 18))
        XCTAssertEqual(official.reset, CGRect(x: 14, y: 28, width: 128, height: 17))
        XCTAssertEqual(official.amount, CGRect(x: 149, y: 18, width: 141, height: 48))
        XCTAssertEqual(official.progress, CGRect(x: 14, y: 8, width: 276, height: 5))
        XCTAssertNil(official.linkPrefix)
        XCTAssertNil(official.link)

        let balance = OpenCodexCardLayout.frames(for: .balance, linkPrefixWidth: 62)
        XCTAssertEqual(balance.cardSize, CGSize(width: 304, height: 102))
        XCTAssertEqual(balance.title, CGRect(x: 14, y: 75, width: 189, height: 20))
        XCTAssertEqual(balance.refreshTime, CGRect(x: 209, y: 76, width: 81, height: 17))
        XCTAssertNil(balance.account)
        XCTAssertNil(balance.subscription)
        XCTAssertEqual(balance.quotaDetail, CGRect(x: 14, y: 47, width: 128, height: 18))
        XCTAssertNil(balance.reset)
        XCTAssertEqual(balance.amount, CGRect(x: 149, y: 18, width: 141, height: 48))
        XCTAssertEqual(balance.progress, CGRect(x: 14, y: 8, width: 276, height: 5))
        XCTAssertEqual(balance.linkPrefix, CGRect(x: 14, y: 28, width: 62, height: 17))
        XCTAssertEqual(balance.link, CGRect(x: 75, y: 28, width: 148, height: 17))

        let englishBalance = OpenCodexCardLayout.frames(for: .balance, linkPrefixWidth: 72)
        XCTAssertEqual(englishBalance.linkPrefix, CGRect(x: 14, y: 28, width: 72, height: 17))
        XCTAssertEqual(englishBalance.link, CGRect(x: 85, y: 28, width: 136, height: 17))
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
                $0.amount.height == OpenCodexCardLayout.lunaReserveNoProgressAmountHeight
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
    }

    func testOfficialQuotaLayoutKeepsBankedResetCompactGapWhenQuotaProgressIsHidden() throws {
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 82,
                label: "5-hour",
                daysText: "5 hours",
                reset: "2h",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 82,
                label: "7-day",
                daysText: "7 days",
                reset: "7d",
                durationSeconds: 604_800
            )
        ]
        let withProgress = OpenCodexCardLayout.frames(
            for: .quota,
            officialQuotaWindows: windows,
            includesQuotaProgress: true,
            includesBankedReset: true,
            bankedResetCardCount: 2,
            bankedResetDisplayMode: .compact
        )
        let withoutProgress = OpenCodexCardLayout.frames(
            for: .quota,
            officialQuotaWindows: windows,
            includesQuotaProgress: false,
            includesBankedReset: true,
            bankedResetCardCount: 2,
            bankedResetDisplayMode: .compact
        )
        let compactOn = try XCTUnwrap(withProgress.bankedResetSummaryRow)
        let compactOff = try XCTUnwrap(withoutProgress.bankedResetSummaryRow)
        let noProgressRowHeight = OpenCodexCardLayout.lunaReserveNoProgressRowHeight
        let rowGap = OpenCodexCardLayout.quotaRowGap

        XCTAssertEqual(compactOff.quotaDetail, compactOn.quotaDetail)
        XCTAssertEqual(compactOff.reset, compactOn.reset)
        XCTAssertEqual(compactOff.amount, compactOn.amount)
        XCTAssertEqual(withProgress.quotaRows[1].progress.minY, withoutProgress.quotaRows[1].amount.minY)
        XCTAssertEqual(
            withoutProgress.quotaRows[0].amount.minY
                - (withoutProgress.quotaRows[1].amount.minY + noProgressRowHeight),
            rowGap,
            accuracy: 0.001
        )
        XCTAssertEqual(
            withProgress.quotaRows[0].progress.minY
                - (withProgress.quotaRows[1].progress.minY + OpenCodexCardLayout.quotaRowHeight),
            rowGap,
            accuracy: 0.001
        )
        let bankedBoxMaxY = compactOff.amount.minY + noProgressRowHeight
        XCTAssertEqual(
            withoutProgress.quotaRows[1].amount.minY - bankedBoxMaxY,
            rowGap,
            accuracy: 0.001
        )
        XCTAssertEqual(
            withProgress.quotaRows[1].progress.minY
                - (compactOn.amount.minY + noProgressRowHeight),
            rowGap,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(compactOff.quotaDetail.maxY, bankedBoxMaxY + 0.001)
        XCTAssertGreaterThan(withoutProgress.quotaRows[1].amount.minY, compactOff.quotaDetail.maxY)
    }

    func testOpenAIAccountRowAddsASeparatedSubtitleBeforeQuotaDetails() {
        let frames = OpenCodexCardLayout.frames(for: .quota, includesAccount: true)

        XCTAssertEqual(frames.cardSize, CGSize(width: 304, height: 121))
        XCTAssertEqual(frames.title, CGRect(x: 14, y: 94, width: 189, height: 20))
        XCTAssertEqual(frames.refreshTime, CGRect(x: 209, y: 95, width: 81, height: 17))
        XCTAssertEqual(frames.account, CGRect(x: 14, y: 75, width: 276, height: 17))
        XCTAssertNil(frames.subscription)
        XCTAssertEqual(frames.quotaDetail, CGRect(x: 14, y: 47, width: 128, height: 18))
        XCTAssertEqual(frames.reset, CGRect(x: 14, y: 28, width: 128, height: 17))
        XCTAssertEqual(frames.amount, CGRect(x: 149, y: 18, width: 141, height: 48))
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

        XCTAssertEqual(frames.cardSize, CGSize(width: 304, height: 121))
        XCTAssertEqual(frames.account, CGRect(x: 14, y: 75, width: 234, height: 17))
        XCTAssertEqual(frames.subscription, CGRect(x: 212, y: 75, width: 78, height: 17))
        XCTAssertEqual(frames.title, CGRect(x: 14, y: 94, width: 189, height: 20))
        XCTAssertEqual(frames.refreshTime, CGRect(x: 209, y: 95, width: 81, height: 17))
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

        XCTAssertEqual(frames.cardSize, CGSize(width: 304, height: 199))
        XCTAssertEqual(frames.quotaRows.count, 2)
        XCTAssertEqual(frames.account, CGRect(x: 14, y: 153, width: 198, height: 17))
        XCTAssertEqual(frames.subscription, CGRect(x: 212, y: 153, width: 78, height: 17))
        XCTAssertEqual(frames.title, CGRect(x: 14, y: 172, width: 189, height: 20))
        XCTAssertEqual(frames.refreshTime, CGRect(x: 209, y: 173, width: 81, height: 17))

        let fiveHour = frames.quotaRows[0]
        let sevenDay = frames.quotaRows[1]
        XCTAssertGreaterThan(fiveHour.progress.minY, sevenDay.progress.minY)
        XCTAssertEqual(
            fiveHour.progress.minY - (sevenDay.progress.minY + OpenCodexCardLayout.quotaRowHeight),
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
            XCTAssertEqual(row.amount.height, baseline.amount.height)
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
        XCTAssertEqual(frames.cardSize.height, 273)
        XCTAssertEqual(
            frames.lunaReserveRow?.progress.minY,
            OpenCodexCardLayout.quotaBottomInset
                + OpenCodexCardLayout.quotaRowHeight
                + OpenCodexCardLayout.quotaRowGap
        )
        XCTAssertEqual(
            frames.quotaRows[1].progress.minY,
            OpenCodexCardLayout.quotaBottomInset
        )
        XCTAssertEqual(
            frames.quotaRows[0].progress.minY,
            frames.lunaReserveRow!.progress.minY
                + OpenCodexCardLayout.quotaRowHeight
                + OpenCodexCardLayout.quotaRowGap
        )

        let unavailableFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesLunaReserve: true,
            includesLunaReserveProgress: false
        )
        XCTAssertEqual(unavailableFrames.cardSize.height, 255)
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
                + OpenCodexCardLayout.quotaRowHeight
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

    func testOfficialQuotaLayoutPlacesBankedResetBlockBelowQuotaRowsWithoutProgress() {
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
        let baseline = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows
        )
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 2
        )

        XCTAssertEqual(frames.quotaRows.count, 2)
        XCTAssertNil(frames.lunaReserveRow)
        guard let summary = frames.bankedResetSummaryRow else {
            XCTFail("expected detailed banked-reset summary row")
            return
        }
        XCTAssertEqual(frames.bankedResetDetailRows.count, 2)
        XCTAssertGreaterThan(frames.cardSize.height, baseline.cardSize.height)
        let hidden = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: false,
            bankedResetCardCount: 2
        )
        XCTAssertEqual(hidden.cardSize, baseline.cardSize)
        XCTAssertNil(hidden.bankedResetSummaryRow)
        XCTAssertTrue(hidden.bankedResetDetailRows.isEmpty)
        XCTAssertEqual(hidden.quotaRows.map(\.quotaDetail), baseline.quotaRows.map(\.quotaDetail))
        let zeroCompact = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 0,
            bankedResetDisplayMode: .compact
        )
        let zeroDetailed = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 0,
            bankedResetDisplayMode: .detailed
        )
        XCTAssertNotNil(zeroCompact.bankedResetSummaryRow)
        XCTAssertNotNil(zeroDetailed.bankedResetSummaryRow)
        XCTAssertTrue(zeroCompact.bankedResetDetailRows.isEmpty)
        XCTAssertTrue(zeroDetailed.bankedResetDetailRows.isEmpty)
        XCTAssertEqual(zeroCompact.cardSize, zeroDetailed.cardSize)
        XCTAssertGreaterThan(zeroCompact.cardSize.height, baseline.cardSize.height)
        XCTAssertLessThan(zeroCompact.cardSize.height, frames.cardSize.height)
        XCTAssertEqual(summary.progress, .zero)
        XCTAssertGreaterThan(summary.amount.width, 0)
        XCTAssertEqual(
            summary.amount.height,
            OpenCodexCardLayout.lunaReserveNoProgressAmountHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(frames.bankedResetDetailRows.map(\.progress), [.zero, .zero])
        XCTAssertEqual(summary.icon, .zero)
        XCTAssertEqual(summary.window, .zero)
        XCTAssertEqual(summary.chrome, .zero)
        XCTAssertEqual(summary.badge, .zero)
        XCTAssertGreaterThan(summary.reset.height, 0)
        XCTAssertGreaterThan(summary.reset.width, 100)
        XCTAssertGreaterThan(summary.quotaDetail.minY, summary.reset.minY)
        XCTAssertEqual(
            frames.bankedResetDetailRows.map(\.icon.size),
            [
                OpenCodexCardLayout.bankedResetTicketIconSize,
                OpenCodexCardLayout.bankedResetTicketIconSize
            ]
        )
        XCTAssertEqual(
            frames.bankedResetDetailRows.map(\.chrome.size),
            [
                CGSize(
                    width: OpenCodexCardLayout.contentWidth,
                    height: OpenCodexCardLayout.bankedResetDetailRowHeight
                ),
                CGSize(
                    width: OpenCodexCardLayout.contentWidth,
                    height: OpenCodexCardLayout.bankedResetDetailRowHeight
                )
            ]
        )
        XCTAssertEqual(
            frames.bankedResetDetailRows[0].chrome.minX,
            frames.bankedResetDetailRows[1].chrome.minX,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(frames.bankedResetDetailRows[0].window.height, 0)
        XCTAssertGreaterThan(frames.bankedResetDetailRows[0].window.width, 180)
        XCTAssertGreaterThan(frames.bankedResetDetailRows[0].reset.width, 180)
        XCTAssertEqual(
            frames.bankedResetDetailRows[0].quotaDetail.minY
                - frames.bankedResetDetailRows[0].reset.minY,
            OpenCodexCardLayout.quotaResetHeight
                + OpenCodexCardLayout.quotaResetHeight
                + 4,
            accuracy: 0.001
        )
        XCTAssertEqual(
            frames.quotaRows[1].progress.minY - (
                frames.bankedResetDetailRows[0].chrome.maxY
                    + OpenCodexCardLayout.bankedResetSummaryDetailGap
                    + OpenCodexCardLayout.lunaReserveNoProgressRowHeight
            ),
            OpenCodexCardLayout.quotaRowGap,
            accuracy: 0.001
        )
        XCTAssertEqual(
            summary.reset.minY
                - frames.bankedResetDetailRows[0].chrome.maxY,
            OpenCodexCardLayout.bankedResetSummaryDetailGap
                + OpenCodexCardLayout.quotaResetOffset
                - (
                    OpenCodexCardLayout.quotaRowHeight
                        - OpenCodexCardLayout.lunaReserveNoProgressRowHeight
                ),
            accuracy: 0.001
        )
        XCTAssertLessThan(
            summary.quotaDetail.minY - summary.reset.maxY,
            4
        )
        XCTAssertGreaterThan(
            summary.quotaDetail.minY,
            frames.bankedResetDetailRows[0].quotaDetail.minY
        )
        XCTAssertGreaterThan(
            frames.bankedResetDetailRows[0].quotaDetail.minY,
            frames.bankedResetDetailRows[1].quotaDetail.minY
        )
        let firstDetail = frames.bankedResetDetailRows[0]
        XCTAssertEqual(
            firstDetail.icon.midY,
            (firstDetail.reset.minY + firstDetail.quotaDetail.maxY) / 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            firstDetail.amount.midY,
            firstDetail.chrome.midY,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(firstDetail.icon.minY, firstDetail.chrome.minY)
        XCTAssertLessThan(firstDetail.icon.maxY, firstDetail.chrome.maxY)
        XCTAssertEqual(
            frames.quotaRows[0].progress.minY - frames.quotaRows[1].progress.minY,
            OpenCodexCardLayout.quotaRowHeight + OpenCodexCardLayout.quotaRowGap,
            accuracy: 0.001
        )

        let withoutCards = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows
        )
        XCTAssertEqual(withoutCards.cardSize, baseline.cardSize)
        XCTAssertNil(withoutCards.bankedResetSummaryRow)
        XCTAssertTrue(withoutCards.bankedResetDetailRows.isEmpty)

        let compact = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 2,
            bankedResetDisplayMode: .compact
        )
        XCTAssertTrue(compact.bankedResetDetailRows.isEmpty)
        guard let compactSummary = compact.bankedResetSummaryRow else {
            XCTFail("expected compact banked-reset summary row")
            return
        }
        XCTAssertGreaterThan(compactSummary.amount.width, 0)
        XCTAssertEqual(compactSummary.badge, .zero)
        XCTAssertEqual(compactSummary.chrome, .zero)
        XCTAssertGreaterThan(compactSummary.reset.width, 0)
        XCTAssertLessThan(compact.cardSize.height, frames.cardSize.height)
        XCTAssertGreaterThan(compact.cardSize.height, baseline.cardSize.height)
        XCTAssertEqual(
            compactSummary.amount.height,
            OpenCodexCardLayout.lunaReserveNoProgressAmountHeight,
            accuracy: 0.001
        )
        XCTAssertFalse(OpenCodexCardLayout.bankedResetTicketsNeedScroll(cardCount: 2))
        guard let twoTicketViewport = frames.bankedResetTicketViewport else {
            XCTFail("expected unclipped ticket viewport for two cards")
            return
        }
        XCTAssertEqual(
            twoTicketViewport.height,
            OpenCodexCardLayout.bankedResetTicketStackHeight(cardCount: 2),
            accuracy: 0.001
        )
        XCTAssertEqual(
            twoTicketViewport.minY,
            OpenCodexCardLayout.quotaBottomInset,
            accuracy: 0.001
        )
        XCTAssertNil(compact.bankedResetTicketViewport)
        XCTAssertNil(withoutCards.bankedResetTicketViewport)
    }

    func testOfficialQuotaLayoutClipsDetailedBankedResetTicketsToTwoAndAHalfRows() {
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
        let two = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 2
        )
        let three = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 3
        )
        let ten = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 10
        )

        XCTAssertEqual(
            OpenCodexCardLayout.bankedResetTicketViewportMaxHeight,
            208,
            accuracy: 0.001
        )
        XCTAssertFalse(OpenCodexCardLayout.bankedResetTicketsNeedScroll(cardCount: 1))
        XCTAssertFalse(OpenCodexCardLayout.bankedResetTicketsNeedScroll(cardCount: 2))
        XCTAssertTrue(OpenCodexCardLayout.bankedResetTicketsNeedScroll(cardCount: 3))
        XCTAssertTrue(OpenCodexCardLayout.bankedResetTicketsNeedScroll(cardCount: 10))

        XCTAssertEqual(three.bankedResetDetailRows.count, 3)
        XCTAssertEqual(ten.bankedResetDetailRows.count, 10)
        guard let threeViewport = three.bankedResetTicketViewport,
              let tenViewport = ten.bankedResetTicketViewport else {
            XCTFail("expected clipped ticket viewports for three and ten cards")
            return
        }
        XCTAssertEqual(
            threeViewport.height,
            OpenCodexCardLayout.bankedResetTicketViewportMaxHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            tenViewport.height,
            OpenCodexCardLayout.bankedResetTicketViewportMaxHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ten.cardSize.height - two.cardSize.height,
            OpenCodexCardLayout.bankedResetVisibleTicketStackHeight(cardCount: 10)
                - OpenCodexCardLayout.bankedResetTicketStackHeight(cardCount: 2),
            accuracy: 0.001
        )
        XCTAssertEqual(ten.cardSize.height, three.cardSize.height, accuracy: 0.001)
        XCTAssertGreaterThan(ten.cardSize.height, two.cardSize.height)

        let firstChrome = ten.bankedResetDetailRows[0].chrome
        let lastChrome = ten.bankedResetDetailRows[9].chrome
        XCTAssertEqual(lastChrome.minY, 0, accuracy: 0.001)
        XCTAssertEqual(
            firstChrome.maxY,
            OpenCodexCardLayout.bankedResetTicketStackHeight(cardCount: 10),
            accuracy: 0.001
        )
        XCTAssertGreaterThan(firstChrome.minY, lastChrome.minY)

        guard let summary = ten.bankedResetSummaryRow else {
            XCTFail("expected clipped ticket summary")
            return
        }
        let viewport = tenViewport
        XCTAssertEqual(
            ten.quotaRows[1].progress.minY - (
                viewport.maxY
                    + OpenCodexCardLayout.bankedResetSummaryDetailGap
                    + OpenCodexCardLayout.lunaReserveNoProgressRowHeight
            ),
            OpenCodexCardLayout.quotaRowGap,
            accuracy: 0.001
        )
        XCTAssertEqual(
            summary.reset.minY - viewport.maxY,
            OpenCodexCardLayout.bankedResetSummaryDetailGap
                + OpenCodexCardLayout.quotaResetOffset
                - (
                    OpenCodexCardLayout.quotaRowHeight
                        - OpenCodexCardLayout.lunaReserveNoProgressRowHeight
                ),
            accuracy: 0.001
        )
        XCTAssertGreaterThan(summary.quotaDetail.minY, viewport.maxY)
        XCTAssertLessThan(
            two.bankedResetDetailRows[0].chrome.maxY,
            OpenCodexCardLayout.bankedResetTicketStackHeight(cardCount: 10)
        )
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
