import XCTest
@testable import BalanceBar

final class DiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ kind: FetchSchedulerLogEvent.Kind, ago: TimeInterval, outcome: String? = nil, cooldown: TimeInterval = 0
    ) -> FetchSchedulerLogEvent {
        FetchSchedulerLogEvent(
            kind: kind, reasons: [.scheduled], skipReason: nil, tokens: 3,
            cooldownRemaining: cooldown, outcome: outcome, timestamp: now.addingTimeInterval(-ago))
    }

    private func mergeState(source: String, trust: QuotaTrust, receivedAgo: TimeInterval) -> QuotaMergeState {
        let obs = QuotaObservation(
            window: .fiveHour, usedPercentage: 10, receivedAt: now.addingTimeInterval(-receivedAgo),
            source: source, trust: trust, accountID: "acct", epoch: .initial)!
        let reading = QuotaMergedReading(obs)
        return QuotaMergeState(windows: ["five_hour": QuotaMergedWindow(displayed: reading, latestGradeA: nil, pendingResetOf: nil)])
    }

    private func lines(_ inputs: DiagnosticsInputs) -> [String] {
        DiagnosticsContent.items(inputs, formatTime: { "T-\(Int(self.now.timeIntervalSince($0)))" }).map(\.snapshotLine)
    }

    func testSourceListSnapshotCoversHealthStates() {
        var inputs = DiagnosticsInputs(now: now)
        inputs.hudExportDetected = true
        inputs.adapters = [
            .init(sourceID: "inbox", trust: .b, health: .healthy),
            .init(sourceID: "codex", trust: .b, health: .degraded(reason: "校验失败：文件过大")),
            .init(sourceID: "mod", trust: .a, health: .unavailable(reason: "目录不存在")),
        ]
        inputs.mergeState = mergeState(source: "inbox", trust: .b, receivedAgo: 30)
        XCTAssertEqual(lines(inputs), [
            "# 数据来源诊断",
            "## 数据来源",
            "codex · 降级 · 最近更新 暂无匹配的更新记录 · 可信度 B 级（需校验）",
            "    原因：校验失败：文件过大",
            "inbox · 正常 · 最近更新 T-30 · 可信度 B 级（需校验）",
            "mod · 不可用 · 最近更新 暂无匹配的更新记录 · 可信度 A 级（可信）",
            "    原因：目录不存在",
            "## 请求统计",
            "近 1 小时请求：0 次",
            "近 1 小时 429：0 次",
            "冷却剩余：无",
        ])
    }

    func testMergedSourceWithoutAdapterIsListedAsActive() {
        var inputs = DiagnosticsInputs(now: now)
        inputs.hudExportDetected = true
        inputs.mergeState = mergeState(source: "api", trust: .a, receivedAgo: 5)
        let rows = DiagnosticsContent.sourceRows(inputs)
        XCTAssertEqual(rows, [DiagnosticsSourceRow(
            sourceID: "api", status: .active, lastUpdated: now.addingTimeInterval(-5), trust: .a, reason: nil)])
    }

    func testRequestStatsCountWindowRateLimitsAndCooldown() {
        let events = [
            event(.dispatched, ago: 4_000),                       // outside the 1h window
            event(.dispatched, ago: 3_000),
            event(.completed, ago: 2_990, outcome: "success"),
            event(.dispatched, ago: 600),
            event(.completed, ago: 590, outcome: "rate_limited", cooldown: 900),
            event(.skipped, ago: 100, cooldown: 790),
        ]
        let stats = DiagnosticsRequestStats(events: events, now: now)
        XCTAssertEqual(stats.requestsInWindow, 2)
        XCTAssertEqual(stats.rateLimitedInWindow, 1)
        XCTAssertEqual(stats.cooldownRemaining, 690, accuracy: 0.001)
    }

    func testCooldownDecaysToZeroAndNeverNegative() {
        let stats = DiagnosticsRequestStats(events: [event(.skipped, ago: 1_000, cooldown: 100)], now: now)
        XCTAssertEqual(stats.cooldownRemaining, 0)
    }

    func testEstimationSectionOnlyWhenProvided() {
        var inputs = DiagnosticsInputs(now: now)
        inputs.hudExportDetected = true
        XCTAssertFalse(lines(inputs).contains("## 估算误差"))
        inputs.estimation = DiagnosticsEstimationSummary(sampleCount: 8, meanAbsoluteError: 1.5, maxAbsoluteError: 3)
        let out = lines(inputs)
        XCTAssertTrue(out.contains("## 估算误差"))
        XCTAssertTrue(out.contains("样本 8 个 · 平均误差 1.5 个百分点 · 最大误差 3.0 个百分点"))
    }

    func testHUDExplanationShownOnlyWithoutExport() {
        var inputs = DiagnosticsInputs(now: now)
        inputs.inboxDirectory = URL(fileURLWithPath: "/tmp/inbox")
        let without = lines(inputs)
        XCTAssertTrue(without.contains("## HUD 额度导出"))
        XCTAssertTrue(without.contains("$ /tmp/inbox"))
        inputs.hudExportDetected = true
        XCTAssertFalse(lines(inputs).contains("## HUD 额度导出"))
    }

    func testHUDExampleIsAValidSnapshot() throws {
        let data = Data(DiagnosticsContent.hudExample.utf8)
        XCTAssertNoThrow(try SnapshotValidatingProbe.decode(data))
    }

    func testDiscardedStaleEpochRateLimitIsCounted() {
        let events = [
            event(.dispatched, ago: 300),
            event(.discardedStaleEpoch, ago: 200, outcome: "rate_limited", cooldown: 900),
            event(.discardedStaleEpoch, ago: 150, outcome: "success", cooldown: 750),
        ]
        let stats = DiagnosticsRequestStats(events: events, now: now)
        XCTAssertEqual(stats.rateLimitedInWindow, 1)
        XCTAssertGreaterThan(stats.cooldownRemaining, 0)
    }

    func testAdapterUpdateTimeFollowsObservedSourceIDs() {
        var inputs = DiagnosticsInputs(now: now)
        inputs.hudExportDetected = true
        inputs.adapters = [.init(sourceID: "inbox", trust: .b, health: .healthy, observedSourceIDs: ["claude-hud"])]
        inputs.mergeState = mergeState(source: "claude-hud", trust: .b, receivedAgo: 20)
        let rows = DiagnosticsContent.sourceRows(inputs)
        XCTAssertEqual(rows.count, 1, "observed source must not be listed separately")
        XCTAssertEqual(rows.first?.sourceID, "inbox")
        XCTAssertEqual(rows.first?.lastUpdated, now.addingTimeInterval(-20))
    }

    func testUnmatchedAdapterIsNotReportedAsNeverUpdated() {
        var inputs = DiagnosticsInputs(now: now)
        inputs.hudExportDetected = true
        inputs.adapters = [.init(sourceID: "inbox", trust: .b, health: .healthy)]
        XCTAssertTrue(lines(inputs).contains("inbox · 正常 · 最近更新 暂无匹配的更新记录 · 可信度 B 级（需校验）"))
    }

    func testLongContentIsScrollableInWindow() {
        var inputs = DiagnosticsInputs(now: now)
        inputs.adapters = (0..<12).map {
            .init(sourceID: "source-\($0)", trust: .b, health: .degraded(reason: String(repeating: "原因说明 ", count: 20)))
        }
        let controller = DiagnosticsWindowController(provider: { inputs })
        controller.show()
        defer { controller.window?.close() }
        let scroll = controller.window?.contentView as? NSScrollView
        XCTAssertNotNil(scroll)
        XCTAssertTrue(scroll?.hasVerticalScroller ?? false)
        XCTAssertTrue(controller.window?.styleMask.contains(.resizable) ?? false)
        XCTAssertTrue(scroll?.documentView === controller.contentView)
        XCTAssertGreaterThan(controller.contentView.frame.height, 400)
    }

    func testViewIsReadOnlyAndRendersItems() {
        let view = DiagnosticsView()
        var inputs = DiagnosticsInputs(now: now)
        inputs.hudExportDetected = true
        view.reload(DiagnosticsContent.items(inputs))
        XCTAssertEqual(view.snapshotLines.first, "# 数据来源诊断")
        func buttons(in v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? [] + v.subviews.flatMap(buttons) }
        XCTAssertTrue(buttons(in: view).isEmpty)
    }
}

private enum SnapshotValidatingProbe {
    static func decode(_ data: Data) throws {
        _ = try QuotaSnapshotParser.parse(data)
    }
}
