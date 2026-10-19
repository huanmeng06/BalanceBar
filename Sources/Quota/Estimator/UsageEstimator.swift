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

    private struct WindowState {
        var anchorPercent: Double
        var anchorAt: Date
        var resetsAt: Date?
        var rawUnitsByModel: [String: Double] = [:]
        var sessions: Set<String> = []
        var sawSidechain = false
        var recordCount = 0
        var totalTokens = 0
        var cacheTokens = 0
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
    private var seenKeys: Set<String> = []
    private var seenOrder: [String] = []
    private var seenHead = 0

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

    /// Parses, deduplicates by request/message, attributes and accumulates transcript lines.
    /// Returns the number of records counted.
    @discardableResult
    public func ingest(lines: [Data]) -> Int {
        let records = lines.compactMap(TranscriptUsageParser.parse)
        lock.lock(); defer { lock.unlock() }
        var counted = 0
        for record in records where remember(record.deduplicationKey) && remember("u:" + record.uuid) {
            guard case let .attributed(accountID) = attributor.attribute(record) else { continue }
            let raw = weights.rawUnits(for: record)
            for key in states.keys where key.accountID == accountID {
                guard record.timestamp >= states[key]!.anchorAt else { continue }
                states[key]!.rawUnitsByModel[record.model, default: 0] += raw
                states[key]!.recordCount += 1
                states[key]!.totalTokens += record.totalTokens
                states[key]!.cacheTokens += record.cacheTokens
                if record.isSidechain { states[key]!.sawSidechain = true }
                if let session = record.sessionID { states[key]!.sessions.insert(session) }
            }
            counted += 1
        }
        return counted
    }

    /// Current diagnostic estimate, or `nil` before the first official reading of this window.
    public func estimate(accountID: String, window: QuotaWindowKind) -> UsageEstimate? {
        lock.lock(); defer { lock.unlock() }
        guard let state = states[WindowKey(accountID: accountID, window: window.description)] else { return nil }
        return makeEstimate(state, window: window.description)
    }

    /// Records an official reading: logs estimate vs official, then learns from it.
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
        var entry: ShadowEntry?

        if var state = states[key] {
            let resetOccurred = didReset(state, newResetsAt: resetsAt, percent: percent)
            let base = resetOccurred ? 0 : state.anchorPercent
            let estimateState = WindowState(
                anchorPercent: base, anchorAt: state.anchorAt, resetsAt: state.resetsAt,
                rawUnitsByModel: state.rawUnitsByModel, sessions: state.sessions,
                sawSidechain: state.sawSidechain, recordCount: state.recordCount,
                totalTokens: state.totalTokens, cacheTokens: state.cacheTokens)
            let estimate = makeEstimate(estimateState, window: windowName)
            var scenarios: [String] = []
            if state.rawUnitsByModel.count > 1 { scenarios.append(EstimatorScenario.multiModel) }
            if state.totalTokens > 0,
               Double(state.cacheTokens) / Double(state.totalTokens) >= configuration.cacheHeavyShare {
                scenarios.append(EstimatorScenario.cacheHeavy)
            }
            if state.sawSidechain || state.sessions.count > 1 { scenarios.append(EstimatorScenario.multiAgent) }
            if attributor.switchOccurred(from: state.anchorAt, to: date) { scenarios.append(EstimatorScenario.accountSwitch) }
            if resetOccurred { scenarios.append(EstimatorScenario.resetBoundary) }
            if scenarios.isEmpty { scenarios.append(EstimatorScenario.baseline) }
            let levels = Set(state.rawUnitsByModel.keys.map { weights.multiplier(for: $0).level.rawValue }).sorted()

            let made = ShadowEntry(
                at: date, accountID: accountID, window: windowName, officialPercent: percent,
                estimatedPercent: estimate.percent, anchorPercent: base, recordCount: state.recordCount,
                confidence: estimate.confidence, errorRange: estimate.errorRange,
                scenarios: scenarios, weightLevels: levels)
            entry = made
            log.append(made)

            if !resetOccurred { learn(from: state, official: percent, windowName: windowName, error: abs(made.error)) }
            state.resetsAt = resetsAt ?? state.resetsAt
            state.anchorPercent = percent
            state.anchorAt = date
            state.rawUnitsByModel = [:]
            state.sessions = []
            state.sawSidechain = false
            state.recordCount = 0
            state.totalTokens = 0
            state.cacheTokens = 0
            states[key] = state
        } else {
            states[key] = WindowState(anchorPercent: percent, anchorAt: date, resetsAt: resetsAt)
        }
        return entry
    }

    // MARK: - Private

    private func remember(_ key: String) -> Bool {
        guard seenKeys.insert(key).inserted else { return false }
        seenOrder.append(key)
        while seenOrder.count - seenHead > configuration.maximumDeduplicationKeys {
            seenKeys.remove(seenOrder[seenHead])
            seenHead += 1
        }
        if seenHead > seenOrder.count / 2 { seenOrder.removeFirst(seenHead); seenHead = 0 }
        return true
    }

    private func didReset(_ state: WindowState, newResetsAt: Date?, percent: Double) -> Bool {
        if let old = state.resetsAt, let new = newResetsAt, abs(new.timeIntervalSince(old)) > 60 { return true }
        return percent < state.anchorPercent
    }

    private func units(_ state: WindowState) -> Double {
        state.rawUnitsByModel.reduce(0) { $0 + $1.value * weights.multiplier(for: $1.key).value }
    }

    private func makeEstimate(_ state: WindowState, window: String) -> UsageEstimate {
        let stats = learned[window] ?? Learned(percentPerUnit: configuration.initialPercentPerUnit)
        let percent = min(100, max(state.anchorPercent, state.anchorPercent + units(state) * stats.percentPerUnit))
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

    private func learn(from state: WindowState, official: Double, windowName: String, error: Double) {
        let delta = official - state.anchorPercent
        var stats = learned[windowName] ?? Learned(percentPerUnit: configuration.initialPercentPerUnit)
        let alpha = configuration.learningRate
        stats.meanAbsoluteError = stats.samples == 0 ? error : (1 - alpha) * stats.meanAbsoluteError + alpha * error
        stats.samples += 1

        let before = units(state)
        if delta >= configuration.minimumLearnablePercentDelta, before > 0 {
            let predicted = before * stats.percentPerUnit
            var modelShares: [String: Double] = [:]
            for (model, raw) in state.rawUnitsByModel { modelShares[model] = raw * weights.multiplier(for: model).value / before }
            weights.learn(ratio: delta / predicted, shares: modelShares)
            let after = units(state)
            let implied = delta / after
            stats.percentPerUnit = (1 - alpha) * stats.percentPerUnit + alpha * implied
        }
        learned[windowName] = stats
    }
}
