import Foundation

/// Thresholds for the diagnostics page. Kept in one place so tests and views agree.
enum DiagnosticsConfig {
    /// Window used for the "requests per hour" statistic.
    static let requestStatsWindow: TimeInterval = 60 * 60
}

/// Health of one data source as shown on the diagnostics page.
enum DiagnosticsSourceStatus: String, Equatable {
    case healthy, degraded, unavailable
    /// The source delivered readings but no adapter reports its health (for example the official endpoint).
    case active
}

/// One row of the source list.
struct DiagnosticsSourceRow: Equatable {
    let sourceID: String
    let status: DiagnosticsSourceStatus
    let lastUpdated: Date?
    let trust: QuotaTrust?
    /// Why the source is not healthy (rejected input, missing directory, ...).
    let reason: String?
}

/// Scheduler request statistics derived from the structured log.
struct DiagnosticsRequestStats: Equatable {
    let requestsInWindow: Int
    let rateLimitedInWindow: Int
    let cooldownRemaining: TimeInterval

    init(events: [FetchSchedulerLogEvent], now: Date, window: TimeInterval = DiagnosticsConfig.requestStatsWindow) {
        let cutoff = now.addingTimeInterval(-window)
        let recent = events.filter { $0.timestamp > cutoff && $0.timestamp <= now }
        requestsInWindow = recent.filter { $0.kind == .dispatched }.count
        rateLimitedInWindow = recent.filter { $0.kind == .completed && $0.outcome == "rate_limited" }.count
        if let latest = events.filter({ $0.timestamp <= now }).max(by: { $0.timestamp < $1.timestamp }) {
            cooldownRemaining = max(0, latest.cooldownRemaining - now.timeIntervalSince(latest.timestamp))
        } else {
            cooldownRemaining = 0
        }
    }
}

/// Estimation error summary; supplied only when the estimator (BB-16) is present.
struct DiagnosticsEstimationSummary: Equatable {
    let sampleCount: Int
    /// Mean absolute error in percentage points.
    let meanAbsoluteError: Double
    let maxAbsoluteError: Double
}

/// Read-only inputs: scheduler log (BB-05), merge state (BB-06) and adapter health (BB-11).
struct DiagnosticsInputs {
    struct Adapter: Equatable {
        let sourceID: String
        let trust: QuotaTrust
        let health: QuotaAdapterHealth
    }

    var adapters: [Adapter] = []
    var mergeState: QuotaMergeState?
    var logEvents: [FetchSchedulerLogEvent] = []
    var estimation: DiagnosticsEstimationSummary?
    var hudExportDetected: Bool = false
    var inboxDirectory: URL?
    var now: Date
}

/// One visible element; the view renders exactly this list and tests snapshot it.
enum DiagnosticsItem: Equatable {
    case title(String)
    case section(String)
    case text(String)
    case code(String)

    var snapshotLine: String {
        switch self {
        case let .title(t): return "# \(t)"
        case let .section(t): return "## \(t)"
        case let .text(t): return t
        case let .code(c): return "$ " + c.replacingOccurrences(of: "\n", with: "\n$ ")
        }
    }
}

enum DiagnosticsContent {
    static func sourceRows(_ inputs: DiagnosticsInputs) -> [DiagnosticsSourceRow] {
        var latest: [String: QuotaMergedReading] = [:]
        for window in inputs.mergeState?.windows.values.map({ $0 }) ?? [] {
            for reading in [window.displayed, window.latestGradeA].compactMap({ $0 }) {
                if let known = latest[reading.source], known.receivedAt >= reading.receivedAt { continue }
                latest[reading.source] = reading
            }
        }
        var rows = inputs.adapters.map { adapter -> DiagnosticsSourceRow in
            let status: DiagnosticsSourceStatus
            let reason: String?
            switch adapter.health {
            case .healthy: (status, reason) = (.healthy, nil)
            case let .degraded(r): (status, reason) = (.degraded, r)
            case let .unavailable(r): (status, reason) = (.unavailable, r)
            }
            return DiagnosticsSourceRow(
                sourceID: adapter.sourceID, status: status,
                lastUpdated: latest[adapter.sourceID]?.receivedAt, trust: adapter.trust, reason: reason)
        }
        let known = Set(rows.map(\.sourceID))
        rows += latest.filter { !known.contains($0.key) }.map {
            DiagnosticsSourceRow(sourceID: $0.key, status: .active, lastUpdated: $0.value.receivedAt,
                                 trust: $0.value.trust, reason: nil)
        }
        return rows.sorted { $0.sourceID < $1.sourceID }
    }

    static func items(_ inputs: DiagnosticsInputs, formatTime: (Date) -> String = isoString) -> [DiagnosticsItem] {
        var out: [DiagnosticsItem] = [.title("数据来源诊断"), .section("数据来源")]
        let rows = sourceRows(inputs)
        if rows.isEmpty { out.append(.text("暂无数据来源。")) }
        for row in rows {
            let trust = row.trust.map { $0 == .a ? "A 级（可信）" : "B 级（需校验）" } ?? "—"
            let updated = row.lastUpdated.map(formatTime) ?? "从未更新"
            out.append(.text("\(row.sourceID) · \(statusText(row.status)) · 最近更新 \(updated) · 可信度 \(trust)"))
            if let reason = row.reason { out.append(.text("    原因：\(reason)")) }
        }

        let stats = DiagnosticsRequestStats(events: inputs.logEvents, now: inputs.now)
        out.append(.section("请求统计"))
        out.append(.text("近 1 小时请求：\(stats.requestsInWindow) 次"))
        out.append(.text("近 1 小时 429：\(stats.rateLimitedInWindow) 次"))
        out.append(.text(stats.cooldownRemaining > 0
            ? "冷却剩余：\(Int(stats.cooldownRemaining.rounded(.up))) 秒" : "冷却剩余：无"))

        if let estimation = inputs.estimation {
            out.append(.section("估算误差"))
            out.append(.text(String(format: "样本 %d 个 · 平均误差 %.1f 个百分点 · 最大误差 %.1f 个百分点",
                                    estimation.sampleCount, estimation.meanAbsoluteError, estimation.maxAbsoluteError)))
        }

        if !inputs.hudExportDetected {
            out.append(.section("HUD 额度导出"))
            out.append(.text("未检测到 HUD 导出的额度快照。开启导出后，将下面格式的 JSON 文件写入快照收件箱："))
            if let dir = inputs.inboxDirectory { out.append(.code(dir.path)) }
            out.append(.code(hudExample))
        }
        return out
    }

    static let hudExample = """
    {"updated_at":"2026-01-01T00:00:00Z","source":"claude-hud",
     "five_hour":{"used_percentage":12.5,"resets_at":"2026-01-01T05:00:00Z"},
     "seven_day":{"used_percentage":40,"resets_at":"2026-01-07T00:00:00Z"}}
    """

    private static func statusText(_ status: DiagnosticsSourceStatus) -> String {
        switch status {
        case .healthy: return "正常"
        case .degraded: return "降级"
        case .unavailable: return "不可用"
        case .active: return "有数据"
        }
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
