import AppKit
import XCTest
@testable import BalanceBar

final class OpenCodexCardLayoutTests: XCTestCase {
    func testOverviewMetricsKeepSectionAndTicketSpacingIndependent() {
        let metrics = OverviewLayoutMetrics.default

        XCTAssertEqual(metrics.sectionSpacing, 22)
        XCTAssertEqual(metrics.subsectionSpacing, 16)
        XCTAssertEqual(metrics.quotaRowSpacing, 12)
        XCTAssertEqual(metrics.ticketSpacing, 8)
        XCTAssertEqual(metrics.titleSubtitleSpacing, 2)
        XCTAssertEqual(metrics.subtitleProgressSpacing, 7)
        XCTAssertLessThan(metrics.quotaRowSpacing, metrics.subsectionSpacing)
        XCTAssertLessThan(metrics.subsectionSpacing, metrics.sectionSpacing)
        XCTAssertNotEqual(metrics.sectionSpacing, metrics.titleSubtitleSpacing)
        XCTAssertNotEqual(metrics.sectionSpacing, metrics.subtitleProgressSpacing)

        // The production calculator reads these through separate semantic
        // keys, so changing one layer cannot silently change another.
        XCTAssertEqual(OpenCodexCardLayout.quotaRowGap, metrics.quotaRowSpacing)
        XCTAssertEqual(OpenCodexCardLayout.bankedResetProbabilitySummaryGap,
                       metrics.subsectionSpacing)
    }

    func testExpandedFramesExposeIndependentVisibleSections() throws {
        let windows = [
            OfficialQuotaWindow(kind: .fiveHour, remaining: 80, label: "5h", daysText: "5 hours", reset: "2h", durationSeconds: 18_000),
            OfficialQuotaWindow(kind: .sevenDay, remaining: 45, label: "7d", daysText: "7 days", reset: "7d", durationSeconds: 604_800)
        ]
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 3,
            bankedResetDisplayMode: .detailed
        )

        XCTAssertEqual(frames.sectionLayouts.map(\.id), [.account, .fiveHour, .sevenDay, .resetProbability, .bankedReset])
        XCTAssertTrue(frames.sectionLayouts.allSatisfy { $0.height > 0 })

        let quota = try XCTUnwrap(frames.sectionLayouts.first { $0.id == .fiveHour })
        let probability = try XCTUnwrap(frames.sectionLayouts.first { $0.id == .resetProbability })
        let banked = try XCTUnwrap(frames.sectionLayouts.first { $0.id == .bankedReset })
        XCTAssertEqual(probability.height, OpenCodexCardLayout.bankedResetProbabilityBlockHeight(), accuracy: 0.001)
        XCTAssertGreaterThan(banked.height, probability.height)
        XCTAssertEqual(quota.height, OpenCodexCardLayout.quotaProgressRowHeight)
        XCTAssertEqual(quota.row?.progress.minY, 0)
        XCTAssertEqual(quota.cardRow, frames.quotaRows.first)
    }

    func testSectionCompositionKeepsDocumentCoordinatesOutOfParentBounds() throws {
        let frames = OpenCodexCardLayout.frames(for: .quota, includesBankedReset: true,
            bankedResetCardCount: 8, bankedResetTicketMetrics: Array(repeating:
                .init(titleWidth: 180, windowWidth: 190, resetWidth: 110, amountWidth: 62), count: 8))
        let banked = try XCTUnwrap(frames.sectionLayouts.first { $0.id == .bankedReset })
        let viewport = try XCTUnwrap(frames.bankedResetTicketViewport)
        XCTAssertEqual(frames.bankedResetDetailRows.first?.chrome.maxY, 824)
        XCTAssertEqual(viewport.height, 256)
        XCTAssertEqual(banked.height, OpenCodexCardLayout.bankedResetSummaryHeight()
            + OpenCodexCardLayout.bankedResetSummaryDetailGap + 256)
        XCTAssertEqual(viewport.minY, banked.frame.minY)
        XCTAssertTrue(banked.frame.contains(viewport))
        XCTAssertEqual(frames.sectionLayouts.first?.id, .account)
        XCTAssertNil(frames.account)
    }

    func testVisibleSectionsComposeWithoutOverlappingReserveOrHiddenGaps() throws {
        let windows = [
            OfficialQuotaWindow(kind: .fiveHour, remaining: 80, label: "5h", daysText: "5 hours", reset: "2h", durationSeconds: 18_000),
            OfficialQuotaWindow(kind: .sevenDay, remaining: 45, label: "7d", daysText: "7 days", reset: "7d", durationSeconds: 604_800)
        ]
        for selected in [[windows[0]], [windows[1]], windows, []] {
            for insertion in 0...selected.count {
                for progress in [true, false] {
                    for probability in [true, false] {
                        for banked in [true, false] {
                            let frames = OpenCodexCardLayout.frames(for: .quota,
                                officialQuotaWindows: selected, includesLunaReserve: true,
                                lunaReserveInsertionIndex: insertion, includesQuotaProgress: progress,
                                includesBankedReset: banked, includesResetProbability: probability)
                            let sections = frames.sectionLayouts
                            XCTAssertEqual(sections.filter { $0.id == .account }.count, 1)
                            XCTAssertEqual(frames.quotaRows.count, selected.count)
                            XCTAssertEqual(sections.count, 2 + selected.count + (probability ? 1 : 0) + (banked ? 1 : 0))
                            var gaps: CGFloat = 0
                            for (upper, lower) in zip(sections, sections.dropFirst()) {
                                let expected: CGFloat = upper.id == .account ? 11
                                    : upper.id == .resetProbability && lower.id == .bankedReset ? 16
                                    : lower.id == .resetProbability || lower.id == .bankedReset ? 22 : 12
                                XCTAssertEqual(upper.frame.minY - lower.frame.maxY, expected, accuracy: 0.001)
                                XCTAssertTrue(upper.frame.intersection(lower.frame).isEmpty)
                                gaps += expected
                            }
                            XCTAssertEqual(frames.cardSize.height, sections.reduce(0) { $0 + $1.height } + gaps + 8 + 7)
                        }
                    }
                }
            }
        }
        for window in windows {
            let frames = OpenCodexCardLayout.frames(for: .quota, officialQuotaWindows: [window])
            XCTAssertEqual(frames.quotaRows.count, 1)
            XCTAssertEqual(frames.sectionLayouts.map(\.id), [.account, .quota(window, index: 0)])
        }
    }

    func testRealLocalizedTicketMeasurementsSelectOnlyOnCompetingWindowLine() throws {
        let previous = AppLanguage.selected
        defer { AppLanguage.selected = previous }
        for language in [AppLanguage.simplifiedChinese, .english, .spanish, .german, .french] {
            AppLanguage.selected = language
            func measured(_ text: String, _ font: NSFont) -> CGFloat {
                let label = NSTextField(labelWithString: text)
                label.font = font
                return max(ceil(label.cell?.cellSize.width ?? 0), ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4)
            }
            let detailFont = NSFont.systemFont(ofSize: 13, weight: .medium)
            let resetFont = NSFont.systemFont(ofSize: 13, weight: .regular)
            let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            let metrics = OpenCodexTicketTextMetrics(
                titleWidth: measured(tr(.keyCodexBankedResetFullResetTitle), detailFont),
                windowWidth: measured(tr(.keyCodexBankedResetFullResetWindow), resetFont),
                resetWidth: measured(CodexBankedResetFormatting.expiryText(for: Date().addingTimeInterval(86400), relativeTo: Date()) ?? "", resetFont),
                amountWidth: measured(language == .simplifiedChinese ? "16 天 16 小时" : "16 d 16 h", amountFont))
            let frames = OpenCodexCardLayout.frames(for: .quota, includesBankedReset: true,
                bankedResetCardCount: 1, bankedResetTicketMetrics: [metrics])
            let row = try XCTUnwrap(frames.bankedResetDetailRows.first)
            let fullWidth = row.chrome.maxX - 12 - row.quotaDetail.minX
            let expanded = metrics.windowWidth + metrics.amountWidth + 6 > fullWidth
            XCTAssertEqual(row.chrome.height, expanded ? 96 : 72, language.rawValue)
            XCTAssertEqual(row.quotaDetail.width, fullWidth)
            XCTAssertEqual(row.reset.width, fullWidth)
            XCTAssertEqual(row.amount.maxX, row.chrome.maxX - 12)
            XCTAssertTrue(row.window.intersection(row.amount).isEmpty)
            if !expanded {
                XCTAssertGreaterThanOrEqual(row.window.width, metrics.windowWidth)
                XCTAssertGreaterThanOrEqual(row.amount.width, metrics.amountWidth)
                XCTAssertEqual(row.amount.midY, row.window.midY)
            }
        }
    }

    func testIndependentTicketLinesDoNotForceExpansionForLongTitleOrExpiry() throws {
        let frames = OpenCodexCardLayout.frames(for: .quota, includesBankedReset: true,
            bankedResetCardCount: 1,
            bankedResetTicketMetrics: [.init(titleWidth: 400, windowWidth: 42, resetWidth: 400, amountWidth: 48)])
        let row = try XCTUnwrap(frames.bankedResetDetailRows.first)
        XCTAssertEqual(row.chrome.height, 72)
        XCTAssertEqual(row.quotaDetail.maxX, row.chrome.maxX - 12)
        XCTAssertEqual(row.reset.maxX, row.chrome.maxX - 12)
        XCTAssertLessThanOrEqual(row.window.maxX + 6, row.amount.minX)
        XCTAssertTrue(row.quotaDetail.intersection(row.amount).isEmpty)
        XCTAssertTrue(row.reset.intersection(row.amount).isEmpty)
    }

    func testCompactBankedResetDoesNotReserveTicketSectionHeight() {
        let compact = OpenCodexCardLayout.frames(
            for: .quota,
            officialQuotaWindows: [],
            includesBankedReset: true,
            bankedResetCardCount: 8,
            bankedResetDisplayMode: .compact
        )
        let detailed = OpenCodexCardLayout.frames(
            for: .quota,
            officialQuotaWindows: [],
            includesBankedReset: true,
            bankedResetCardCount: 8,
            bankedResetDisplayMode: .detailed
        )

        XCTAssertNil(compact.bankedResetTicketViewport)
        XCTAssertTrue(compact.sectionLayouts.allSatisfy { $0.id != .bankedReset || $0.height == OpenCodexCardLayout.bankedResetSummaryHeight() })
        XCTAssertGreaterThan(detailed.cardSize.height, compact.cardSize.height)
        XCTAssertEqual(detailed.bankedResetTicketViewport!.height,
                       OpenCodexCardLayout.bankedResetTicketViewportMaxHeight,
                       accuracy: 0.001)
    }

    func testDetailedTicketsUseTighterInternalSpacingAndSharedValueColumn() throws {
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesBankedReset: true,
            bankedResetCardCount: 3,
            bankedResetDisplayMode: .detailed
        )
        let first = try XCTUnwrap(frames.bankedResetDetailRows.first)
        let second = try XCTUnwrap(frames.bankedResetDetailRows.dropFirst().first)

        XCTAssertEqual(first.chrome.minY - second.chrome.minY,
                       OpenCodexCardLayout.bankedResetDetailRowHeight
                           + OpenCodexCardLayout.metrics.ticketSpacing,
                       accuracy: 0.001)
        XCTAssertEqual(first.amount.maxX,
                       first.chrome.maxX - OpenCodexCardLayout.bankedResetChromeInset,
                       accuracy: 0.001)
        XCTAssertEqual(first.icon.midY, first.chrome.midY, accuracy: 0.001)
        XCTAssertEqual(first.amount.midY, first.window.midY, accuracy: 0.001)
        XCTAssertEqual(
            (first.quotaDetail.maxY + first.reset.minY) / 2,
            first.chrome.midY,
            accuracy: 0.001
        )
    }

    func testLongLocalizedTicketTextsUseExpandedRowsWithoutHorizontalOverlap() throws {
        let compactFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesBankedReset: true,
            bankedResetCardCount: 2,
            bankedResetDisplayMode: .detailed,
            bankedResetTicketMetrics: [
                .init(titleWidth: 40, windowWidth: 42, resetWidth: 38, amountWidth: 48)
            ]
        )
        let compactRow = try XCTUnwrap(compactFrames.bankedResetDetailRows.first)
        XCTAssertEqual(compactRow.chrome.height, OpenCodexCardLayout.bankedResetDetailRowHeight)

        let expandedFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesBankedReset: true,
            bankedResetCardCount: 3,
            bankedResetDisplayMode: .detailed,
            bankedResetTicketMetrics: [
                .init(titleWidth: 180, windowWidth: 190, resetWidth: 110, amountWidth: 62),
                .init(titleWidth: 180, windowWidth: 190, resetWidth: 110, amountWidth: 62),
                .init(titleWidth: 180, windowWidth: 190, resetWidth: 110, amountWidth: 62)
            ]
        )
        let first = try XCTUnwrap(expandedFrames.bankedResetDetailRows.first)
        let second = try XCTUnwrap(expandedFrames.bankedResetDetailRows.dropFirst().first)
        XCTAssertEqual(first.chrome.height, OpenCodexCardLayout.bankedResetExpandedDetailRowHeight)
        XCTAssertEqual(
            first.chrome.minY - second.chrome.minY,
            OpenCodexCardLayout.bankedResetExpandedDetailRowHeight
                + OpenCodexCardLayout.metrics.ticketSpacing,
            accuracy: 0.001
        )
        XCTAssertTrue(first.quotaDetail.maxX <= first.chrome.maxX - OpenCodexCardLayout.bankedResetChromeInset)
        XCTAssertTrue(first.window.maxX <= first.chrome.maxX - OpenCodexCardLayout.bankedResetChromeInset)
        XCTAssertTrue(first.amount.minX >= first.quotaDetail.minX)
        XCTAssertTrue(first.amount.maxY <= first.reset.minY)
        XCTAssertTrue(first.quotaDetail.intersection(first.amount).isEmpty)
        XCTAssertTrue(first.window.intersection(first.amount).isEmpty)
        XCTAssertEqual(
            expandedFrames.bankedResetTicketViewport?.height ?? 0,
            OpenCodexCardLayout.bankedResetTicketViewportMaxHeight(
                rowHeight: OpenCodexCardLayout.bankedResetExpandedDetailRowHeight
            ),
            accuracy: 0.001
        )
        XCTAssertTrue(
            OpenCodexCardLayout.bankedResetTicketsNeedScroll(
                cardCount: 3,
                rowHeight: OpenCodexCardLayout.bankedResetExpandedDetailRowHeight
            )
        )
    }

    func testMixedTicketHeightsDriveViewportAndDocumentCoordinates() throws {
        let frames = OpenCodexCardLayout.frames(
            for: .quota, includesBankedReset: true, bankedResetCardCount: 4,
            bankedResetTicketMetrics: [
                .init(titleWidth: 40, windowWidth: 42, resetWidth: 38, amountWidth: 48),
                .init(titleWidth: 180, windowWidth: 190, resetWidth: 110, amountWidth: 62),
                .init(titleWidth: 40, windowWidth: 42, resetWidth: 38, amountWidth: 48),
                .init(titleWidth: 180, windowWidth: 190, resetWidth: 110, amountWidth: 62)
            ]
        )
        let rows = frames.bankedResetDetailRows
        XCTAssertEqual(rows.map(\.chrome.height), [72, 96, 72, 96])
        XCTAssertEqual(try XCTUnwrap(frames.bankedResetTicketViewport).height, 72 + 96 + 36 + 16)
        XCTAssertEqual(rows[0].chrome.maxY, 72 + 96 + 72 + 96 + 24)
        for index in 0..<3 {
            XCTAssertEqual(rows[index].chrome.minY - rows[index + 1].chrome.maxY, 8)
        }
    }

    func testOpenCodexCardLayoutMatchesExistingOfficialAndBalanceOverviewFrames() {
        let official = OpenCodexCardLayout.frames(for: .quota)
        XCTAssertEqual(official.cardSize, CGSize(width: 304, height: 94))
        XCTAssertEqual(official.title, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 67, width: 189, height: 20))
        XCTAssertEqual(official.refreshTime, CGRect(x: OpenCodexCardLayout.refreshTimeX, y: 68, width: 81, height: 17))
        XCTAssertNil(official.account)
        XCTAssertNil(official.subscription)
        XCTAssertEqual(official.quotaDetail, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 39, width: 128, height: 18))
        XCTAssertEqual(official.reset, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 20, width: 128, height: 17))
        XCTAssertEqual(official.amount, CGRect(x: OpenCodexCardLayout.amountX, y: 10, width: OpenCodexCardLayout.amountWidth, height: 48))
        XCTAssertEqual(official.progress, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 8, width: OpenCodexCardLayout.contentWidth, height: 5))
        XCTAssertEqual(
            official.reset!.minY - official.progress!.maxY,
            OpenCodexCardLayout.quotaProgressTopGap,
            accuracy: 0.001
        )
        XCTAssertNil(official.linkPrefix)
        XCTAssertNil(official.link)

        let balance = OpenCodexCardLayout.frames(for: .balance, linkPrefixWidth: 62)
        XCTAssertEqual(balance.cardSize, CGSize(width: 304, height: 94))
        XCTAssertEqual(balance.title, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 67, width: 189, height: 20))
        XCTAssertEqual(balance.refreshTime, CGRect(x: OpenCodexCardLayout.refreshTimeX, y: 68, width: 81, height: 17))
        XCTAssertNil(balance.account)
        XCTAssertNil(balance.subscription)
        XCTAssertEqual(balance.quotaDetail, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 39, width: 128, height: 18))
        XCTAssertNil(balance.reset)
        XCTAssertEqual(balance.amount, CGRect(x: OpenCodexCardLayout.amountX, y: 10, width: OpenCodexCardLayout.amountWidth, height: 48))
        XCTAssertEqual(balance.progress, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 8, width: OpenCodexCardLayout.contentWidth, height: 5))
        XCTAssertEqual(balance.linkPrefix, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 20, width: 62, height: 17))
        XCTAssertEqual(balance.link, CGRect(x: 77, y: 20, width: 148, height: 17))
        XCTAssertEqual(
            balance.link!.minY - balance.progress!.maxY,
            OpenCodexCardLayout.quotaProgressTopGap,
            accuracy: 0.001
        )

        let englishBalance = OpenCodexCardLayout.frames(for: .balance, linkPrefixWidth: 72)
        XCTAssertEqual(englishBalance.linkPrefix, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 20, width: 72, height: 17))
        XCTAssertEqual(englishBalance.link, CGRect(x: 87, y: 20, width: 136, height: 17))
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
        XCTAssertEqual(balance.quotaDetail, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 29, width: 128, height: 18))
        XCTAssertEqual(balance.amount, CGRect(x: OpenCodexCardLayout.amountX, y: 0, width: OpenCodexCardLayout.amountWidth, height: 48))
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
        XCTAssertEqual(metrics.minY - summary.quotaDetail.maxY, OpenCodexCardLayout.bankedResetProbabilitySummaryGap, accuracy: 0.001)
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
        XCTAssertEqual(frames.title, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 86, width: 189, height: 20))
        XCTAssertEqual(frames.refreshTime, CGRect(x: OpenCodexCardLayout.refreshTimeX, y: 87, width: 81, height: 17))
        XCTAssertEqual(frames.account, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 67, width: OpenCodexCardLayout.contentWidth, height: 17))
        XCTAssertNil(frames.subscription)
        XCTAssertEqual(frames.quotaDetail, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 39, width: 128, height: 18))
        XCTAssertEqual(frames.reset, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 20, width: 128, height: 17))
        XCTAssertEqual(frames.amount, CGRect(x: OpenCodexCardLayout.amountX, y: 10, width: OpenCodexCardLayout.amountWidth, height: 48))
        XCTAssertEqual(frames.progress, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 8, width: OpenCodexCardLayout.contentWidth, height: 5))

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
        XCTAssertEqual(frames.account?.minX, OpenCodexCardLayout.horizontalInset)
        XCTAssertEqual(
            frames.account?.width,
            OpenCodexCardLayout.accountWidth(
                forSubscriptionTextWidth: renderedSubscriptionTextWidth
            )
        )
        XCTAssertEqual(frames.subscription, CGRect(x: OpenCodexCardLayout.subscriptionX, y: 67, width: OpenCodexCardLayout.subscriptionWidth, height: 17))
        XCTAssertEqual(frames.title, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 86, width: 189, height: 20))
        XCTAssertEqual(frames.refreshTime, CGRect(x: OpenCodexCardLayout.refreshTimeX, y: 87, width: 81, height: 17))
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
        XCTAssertLessThanOrEqual(
            frames.subscription?.maxX ?? 0,
            frames.cardSize.width - OpenCodexCardLayout.horizontalInset
        )

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

        XCTAssertEqual(frames.cardSize, CGSize(width: 304, height: 181))
        XCTAssertEqual(frames.quotaRows.count, 2)
        XCTAssertEqual(frames.account?.minX, OpenCodexCardLayout.horizontalInset)
        XCTAssertEqual(
            frames.account?.width,
            OpenCodexCardLayout.accountWidth(
                forSubscriptionTextWidth: nil
            )
        )
        XCTAssertEqual(frames.subscription, CGRect(x: OpenCodexCardLayout.subscriptionX, y: 135, width: OpenCodexCardLayout.subscriptionWidth, height: 17))
        XCTAssertEqual(frames.title, CGRect(x: OpenCodexCardLayout.horizontalInset, y: 154, width: 189, height: 20))
        XCTAssertEqual(frames.refreshTime, CGRect(x: OpenCodexCardLayout.refreshTimeX, y: 155, width: 81, height: 17))

        let fiveHour = frames.quotaRows[0]
        let sevenDay = frames.quotaRows[1]
        XCTAssertGreaterThan(fiveHour.progress.minY, sevenDay.progress.minY)
        XCTAssertEqual(
            fiveHour.progress.minY - (sevenDay.progress.minY + OpenCodexCardLayout.quotaProgressRowHeight),
            OpenCodexCardLayout.quotaRowGap,
            accuracy: 0.001
        )
        XCTAssertEqual(fiveHour.progress.width, OpenCodexCardLayout.contentWidth)
        XCTAssertEqual(sevenDay.progress.width, OpenCodexCardLayout.contentWidth)
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
            XCTAssertLessThanOrEqual(
                row.progress.maxX,
                frames.cardSize.width - OpenCodexCardLayout.horizontalInset
            )
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
        XCTAssertEqual(frames.cardSize.height, 245)
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
        XCTAssertEqual(unavailableFrames.cardSize.height, 235)
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
        XCTAssertEqual(probability.reset.minY - summary.quotaDetail.maxY, OpenCodexCardLayout.bankedResetProbabilitySummaryGap, accuracy: 0.001)
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
