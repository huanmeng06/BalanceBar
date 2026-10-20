import Foundation

/// Diagnostic estimate for one account window. Never fed into `QuotaDisplayModel`.
public struct UsageEstimate: Equatable {
    public let percent: Double
    public let confidence: Double
    /// Half-width of the expected error, in percentage points.
    public let errorRange: Double
}

/// Shadow-mode usage estimator.
///
/// Estimate = last official percentage (anchor) + weighted token usage since then × learned rate.
/// Each official reading is compared with the estimate made from the previous anchor and logged,
/// then used to learn (EWMA). Thread-safe; performs no IO itself, so callers invoke it from a
/// background queue after reading transcripts.
public final class UsageEstimator {
    private struct WindowKey: Hashable { let accountID: String; let window: String }

    /// Usage accumulated since an anchor, split by time so a reset boundary can separate cycles.
    private struct Bucket {
        var rawUnitsByModel: [String: Double] = [:]
        var sessions: Set<String> = []
        var sawSidechain = false
        var recordCount = 0
        var totalTokens = 0
        var cacheTokens = 0

        mutating func add(_ contribution: Contribution, sign: Double, countRecord: Bool) {
            rawUnitsByModel[contribution.model, default: 0] = max(0, rawUnitsByModel[contribution.model, default: 0] + sign * contribution.rawUnits)
            totalTokens = max(0, totalTokens + Int(sign) * contribution.totalTokens)
            cacheTokens = max(0, cacheTokens + Int(sign) * contribution.cacheTokens)
            if countRecord {
                recordCount += 1
                if contribution.isSidechain { sawSidechain = true }
                if let session = contribution.sessionID { sessions.insert(session) }
            }
        }

        func merged(with other: Bucket) -> Bucket {
            var result = self
            for (model, units) in other.rawUnitsByModel { result.rawUnitsByModel[model, default: 0] += units }
            result.sessions.formUnion(other.sessions)
            result.sawSidechain = sawSidechain || other.sawSidechain
            result.recordCount += other.recordCount
            result.totalTokens += other.totalTokens
            result.cacheTokens += other.cacheTokens
            return result
        }
    }

    private struct WindowState {
        var anchorPercent: Double
        var anchorAt: Date
        var resetsAt: Date?
        /// Usage before the known reset deadline (or all usage when no deadline is known).
        var beforeReset = Bucket()
        /// Usage at or after the known reset deadline.
        var afterReset = Bucket()
    }

    /// What one request has contributed so far; later records of the same request replace it.
    private struct Contribution: Equatable {
        var accountID: String
        var timestamp: Date
        var model: String
        var rawUnits: Double
        var totalTokens: Int
        var cacheTokens: Int
        var isSidechain: Bool
        var sessionID: String?
    }

    private struct Learned {
        var percentPerUnit: Double
        var meanAbsoluteError = 0.0
        var samples = 0
    }

    private let configuration: EstimatorConfiguration
    private let attributor: UsageAttributor
    private let log: ShadowLogWriting
    private let lock = NSLock()
    private var weights: UsageWeightModel
    private var states: [WindowKey: WindowState] = [:]
    private var learned: [String: Learned] = [:]
    private var contributions: [String: Contribution] = [:]
    private var contributionOrder: [String] = []
    private var contributionHead = 0

    public init(
        configuration: EstimatorConfiguration = EstimatorConfiguration(),
        attributor: UsageAttributor,
        log: ShadowLogWriting
    ) {
        self.configuration = configuration
        self.attributor = attributor
        self.log = log
        weights = UsageWeightModel(configuration: configuration)
    }

    /// Parses, deduplicates, attributes and accumulates transcript lines.
    ///
    /// A repeated message is ignored. A later record of the same request with different usage
    /// (streamed or sub-agent records report early and final totals) replaces the earlier one by
    /// applying the difference. Returns the number of new requests/messages counted.
    @discardableResult
    public func ingest(lines: [Data]) -> Int {
        let records = lines.compactMap(TranscriptUsageParser.parse)
        lock.lock(); defer { lock.unlock() }
        var counted = 0
        for record in records {
            guard case let .attributed(accountID) = attributor.attribute(record) else { continue }
            let new = Contribution(
                accountID: accountID, timestamp: record.timestamp, model: record.model,
                rawUnits: weights.rawUnits(for: record), totalTokens: record.totalTokens,
                cacheTokens: record.cacheTokens, isSidechain: record.isSidechain, sessionID: record.sessionID)
            let key = record.deduplicationKey
            if let previous = contributions[key] {
                // Only a change in usage counts; a repeat with a different timestamp is a no-op.
                guard previous.accountID == accountID, previous.model == new.model,
                      previous.rawUnits != new.rawUnits || previous.totalTokens != new.totalTokens
                        || previous.cacheTokens != new.cacheTokens else { continue }
                applyUpdate(from: previous, to: new)
                contributions[key] = new
            } else {
                apply(new, sign: 1, countRecord: true)
                remember(key, new)
                counted += 1
            }
        }
        return counted
    }

    /// Current diagnostic estimate, or `nil` before the first official reading of this window.
    public func estimate(accountID: String, window: QuotaWindowKind) -> UsageEstimate? {
        lock.lock(); defer { lock.unlock() }
        guard let state = states[WindowKey(accountID: accountID, window: window.description)] else { return nil }
        return makeEstimate(base: state.anchorPercent, bucket: state.beforeReset.merged(with: state.afterReset),
                            window: window.description)
    }

    /// Records an official reading: logs estimate vs official, then learns from it.
    ///
    /// When the reading starts a new cycle only usage at or after the previous cycle's reset
    /// deadline is compared. If that deadline is unknown the cycles cannot be separated, so no
    /// comparison is logged.
    @discardableResult
    public func recordOfficial(
        accountID: String,
        window: QuotaWindowKind,
        percent: Double,
        resetsAt: Date?,
        at date: Date
    ) -> ShadowEntry? {
        lock.lock(); defer { lock.unlock() }
        let windowName = window.description
        let key = WindowKey(accountID: accountID, window: windowName)
        guard var state = states[key] else {
            states[key] = WindowState(anchorPercent: percent, anchorAt: date, resetsAt: resetsAt)
            return nil
        }

        let resetOccurred = didReset(state, newResetsAt: resetsAt, percent: percent)
        var entry: ShadowEntry?
        if !resetOccurred || state.resetsAt != nil {
            let base = resetOccurred ? 0 : state.anchorPercent
            let bucket = resetOccurred ? state.afterReset : state.beforeReset.merged(with: state.afterReset)
            let estimate = makeEstimate(base: base, bucket: bucket, window: windowName)
            var scenarios: [String] = []
            if bucket.rawUnitsByModel.count > 1 { scenarios.append(EstimatorScenario.multiModel) }
            if bucket.totalTokens > 0,
               Double(bucket.cacheTokens) / Double(bucket.totalTokens) >= configuration.cacheHeavyShare {
                scenarios.append(EstimatorScenario.cacheHeavy)
            }
            if bucket.sawSidechain || bucket.sessions.count > 1 { scenarios.append(EstimatorScenario.multiAgent) }
            if attributor.switchOccurred(from: state.anchorAt, to: date) { scenarios.append(EstimatorScenario.accountSwitch) }
            if resetOccurred { scenarios.append(EstimatorScenario.resetBoundary) }
            if scenarios.isEmpty { scenarios.append(EstimatorScenario.baseline) }
            let levels = Set(bucket.rawUnitsByModel.keys.map { weights.multiplier(for: $0).level.rawValue }).sorted()

            let made = ShadowEntry(
                at: date, accountID: accountID, window: windowName, officialPercent: percent,
                estimatedPercent: estimate.percent, anchorPercent: base, recordCount: bucket.recordCount,
                confidence: estimate.confidence, errorRange: estimate.errorRange,
                scenarios: scenarios, weightLevels: levels)
            entry = made
            log.append(made)
            if !resetOccurred {
                learn(from: bucket, anchorPercent: state.anchorPercent, official: percent,
                      windowName: windowName, error: abs(made.error))
            }
        }
        state.resetsAt = resetsAt ?? state.resetsAt
        state.anchorPercent = percent
        state.anchorAt = date
        state.beforeReset = Bucket()
        state.afterReset = Bucket()
        states[key] = state
        return entry
    }

    // MARK: - Private

    private func apply(_ contribution: Contribution, sign: Double, countRecord: Bool) {
        for key in states.keys where key.accountID == contribution.accountID {
            guard contribution.timestamp >= states[key]!.anchorAt else { continue }
            if let reset = states[key]!.resetsAt, contribution.timestamp >= reset {
                states[key]!.afterReset.add(contribution, sign: sign, countRecord: countRecord)
            } else {
                states[key]!.beforeReset.add(contribution, sign: sign, countRecord: countRecord)
            }
        }
    }

    /// Applies the usage difference of a revised request. A window whose anchor is newer than the
    /// original record only receives the growth, never the full revised usage.
    private func applyUpdate(from old: Contribution, to new: Contribution) {
        for key in states.keys where key.accountID == new.accountID {
            let anchorAt = states[key]!.anchorAt
            var delta = new
            delta.rawUnits = new.rawUnits - old.rawUnits
            delta.totalTokens = new.totalTokens - old.totalTokens
            delta.cacheTokens = new.cacheTokens - old.cacheTokens
            if old.timestamp >= anchorAt {
                delta.timestamp = old.timestamp
            } else {
                guard new.timestamp >= anchorAt else { continue }
                delta.rawUnits = max(0, delta.rawUnits)
                delta.totalTokens = max(0, delta.totalTokens)
                delta.cacheTokens = max(0, delta.cacheTokens)
            }
            if let reset = states[key]!.resetsAt, delta.timestamp >= reset {
                states[key]!.afterReset.add(delta, sign: 1, countRecord: false)
            } else {
                states[key]!.beforeReset.add(delta, sign: 1, countRecord: false)
            }
        }
    }

    private func remember(_ key: String, _ contribution: Contribution) {
        contributions[key] = contribution
        contributionOrder.append(key)
        while contributionOrder.count - contributionHead > configuration.maximumDeduplicationKeys {
            contributions.removeValue(forKey: contributionOrder[contributionHead])
            contributionHead += 1
        }
        if contributionHead > contributionOrder.count / 2 {
            contributionOrder.removeFirst(contributionHead)
            contributionHead = 0
        }
    }

    private func didReset(_ state: WindowState, newResetsAt: Date?, percent: Double) -> Bool {
        if let old = state.resetsAt, let new = newResetsAt, abs(new.timeIntervalSince(old)) > 60 { return true }
        return percent < state.anchorPercent
    }

    private func units(_ bucket: Bucket) -> Double {
        bucket.rawUnitsByModel.reduce(0) { $0 + $1.value * weights.multiplier(for: $1.key).value }
    }

    private func makeEstimate(base: Double, bucket: Bucket, window: String) -> UsageEstimate {
        let stats = learned[window] ?? Learned(percentPerUnit: configuration.initialPercentPerUnit)
        let percent = min(100, max(base, base + units(bucket) * stats.percentPerUnit))
        let confidence: Double
        let range: Double
        if stats.samples == 0 {
            confidence = 0
            range = 100
        } else {
            let sampleFactor = min(1, Double(stats.samples) / Double(max(1, configuration.minimumSamples)))
            confidence = sampleFactor / (1 + stats.meanAbsoluteError / 5)
            range = max(configuration.minimumErrorRange, 2 * stats.meanAbsoluteError)
        }
        return UsageEstimate(percent: percent, confidence: confidence, errorRange: range)
    }

    private func learn(from bucket: Bucket, anchorPercent: Double, official: Double, windowName: String, error: Double) {
        let delta = official - anchorPercent
        var stats = learned[windowName] ?? Learned(percentPerUnit: configuration.initialPercentPerUnit)
        let alpha = configuration.learningRate
        stats.meanAbsoluteError = stats.samples == 0 ? error : (1 - alpha) * stats.meanAbsoluteError + alpha * error
        stats.samples += 1

        let before = units(bucket)
        if delta >= configuration.minimumLearnablePercentDelta, before > 0 {
            let predicted = before * stats.percentPerUnit
            var modelShares: [String: Double] = [:]
            for (model, raw) in bucket.rawUnitsByModel { modelShares[model] = raw * weights.multiplier(for: model).value / before }
            weights.learn(ratio: delta / predicted, shares: modelShares)
            let after = units(bucket)
            stats.percentPerUnit = (1 - alpha) * stats.percentPerUnit + alpha * (delta / after)
        }
        learned[windowName] = stats
    }
}
