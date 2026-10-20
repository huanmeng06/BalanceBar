import Foundation

/// Scenario labels used to group the shadow report.
public enum EstimatorScenario {
    public static let multiModel = "multi_model"
    public static let cacheHeavy = "cache_heavy"
    public static let multiAgent = "multi_agent"
    public static let accountSwitch = "account_switch"
    public static let resetBoundary = "reset_boundary"
    public static let baseline = "baseline"
    public static let all = "all"
    public static let ordered = [baseline, multiModel, cacheHeavy, multiAgent, accountSwitch, resetBoundary]
}

/// One "estimate vs official" comparison, recorded when an official reading arrives.
public struct ShadowEntry: Codable, Equatable {
    public var at: Date
    public var accountID: String
    public var window: String
    public var officialPercent: Double
    public var estimatedPercent: Double
    public var anchorPercent: Double
    public var recordCount: Int
    public var confidence: Double
    public var errorRange: Double
    public var scenarios: [String]
    public var weightLevels: [String]

    /// Signed error, estimate minus official, in percentage points.
    public var error: Double { estimatedPercent - officialPercent }
    public var withinRange: Bool { abs(error) <= errorRange }
}

/// Destination of shadow entries. Output goes to diagnostics only, never to `QuotaDisplayModel`.
public protocol ShadowLogWriting: AnyObject {
    func append(_ entry: ShadowEntry)
}

/// In-memory log for tests and diagnostics.
public final class InMemoryShadowLog: ShadowLogWriting {
    private let lock = NSLock()
    private var stored: [ShadowEntry] = []
    public init() {}
    public func append(_ entry: ShadowEntry) { lock.lock(); stored.append(entry); lock.unlock() }
    public var entries: [ShadowEntry] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Appends JSON lines to a private file on a background queue.
public final class ShadowLogFileWriter: ShadowLogWriting {
    private let url: URL
    private let queue = DispatchQueue(label: "BalanceBar.ShadowLog", qos: .utility)
    private let encoder: JSONEncoder

    public init(url: URL) {
        self.url = url
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    public func append(_ entry: ShadowEntry) {
        queue.async { [self] in
            guard var data = try? encoder.encode(entry) else { return }
            data.append(0x0A)
            let manager = FileManager.default
            if !manager.fileExists(atPath: url.path) {
                try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Blocks until queued writes are on disk.
    public func flush() { queue.sync {} }

    /// Reads every parsable entry from a shadow log file.
    public static func readEntries(from url: URL) throws -> [ShadowEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(ShadowEntry.self, from: Data($0.utf8)) }
    }
}

/// Error statistics for one scenario.
public struct ShadowScenarioStats: Equatable {
    public let scenario: String
    public let count: Int
    public let meanAbsoluteError: Double
    public let bias: Double
    public let p95AbsoluteError: Double
    public let withinRangeShare: Double
}

/// Per-scenario error report built from shadow entries.
public struct ShadowReport: Equatable {
    public let stats: [ShadowScenarioStats]

    public init(entries: [ShadowEntry]) {
        var result: [ShadowScenarioStats] = []
        for scenario in [EstimatorScenario.all] + EstimatorScenario.ordered {
            let group = scenario == EstimatorScenario.all ? entries : entries.filter { $0.scenarios.contains(scenario) }
            guard !group.isEmpty else { continue }
            let absolute = group.map { abs($0.error) }.sorted()
            let p95Index = min(absolute.count - 1, Int((Double(absolute.count) * 0.95).rounded(.up)) - 1)
            result.append(ShadowScenarioStats(
                scenario: scenario,
                count: group.count,
                meanAbsoluteError: absolute.reduce(0, +) / Double(absolute.count),
                bias: group.map(\.error).reduce(0, +) / Double(group.count),
                p95AbsoluteError: absolute[max(0, p95Index)],
                withinRangeShare: Double(group.filter(\.withinRange).count) / Double(group.count)
            ))
        }
        stats = result
    }

    /// Plain-text table (percentage points).
    public func render() -> String {
        guard !stats.isEmpty else { return "No shadow entries.\n" }
        var lines = ["scenario          n    MAE   bias    p95  in-range"]
        for item in stats {
            let name = item.scenario.padding(toLength: 14, withPad: " ", startingAt: 0)
            lines.append(name + String(format: " %4d %6.2f %6.2f %6.2f  %5.1f%%",
                                       item.count, item.meanAbsoluteError, item.bias,
                                       item.p95AbsoluteError, item.withinRangeShare * 100))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
