import Foundation

/// Tunables for the estimator. Injected so tests and BB-01 central configuration can override them.
public struct EstimatorConfiguration: Equatable {
    /// Relative cost per token kind (input = 1).
    public var inputWeight = 1.0
    public var outputWeight = 5.0
    public var cacheCreationWeight = 1.25
    public var cacheReadWeight = 0.1
    /// Learning rate of every EWMA.
    public var learningRate = 0.3
    /// Samples a model/family needs before its learned scale is trusted.
    public var minimumSamples = 3
    /// Official deltas below this (percentage points) are rounding noise and are not learned from.
    public var minimumLearnablePercentDelta = 1.0
    /// Initial percentage points per weighted unit before anything is learned.
    public var initialPercentPerUnit = 1.0 / 50_000
    /// Floor of the reported error range, in percentage points.
    public var minimumErrorRange = 2.0
    /// Maximum remembered request keys.
    public var maximumDeduplicationKeys = 100_000
    /// A message mix counts as cache heavy when cache tokens reach this share.
    public var cacheHeavyShare = 0.7

    public init() {}
}

/// Three-level weight resolution: learned model scale, learned family scale, built-in prior.
public struct UsageWeightModel {
    private struct Scale { var value = 1.0; var samples = 0 }

    private let configuration: EstimatorConfiguration
    private var modelScales: [String: Scale] = [:]
    private var familyScales: [String: Scale] = [:]

    public init(configuration: EstimatorConfiguration = EstimatorConfiguration()) {
        self.configuration = configuration
    }

    /// Family name for a model identifier.
    public static func family(of model: String) -> String {
        let lower = model.lowercased()
        for family in ["opus", "sonnet", "haiku"] where lower.contains(family) { return family }
        return "other"
    }

    /// Price-ratio priors, the last-resort level.
    static func prior(forFamily family: String) -> Double {
        switch family {
        case "opus": return 5
        case "haiku": return 0.33
        default: return 1
        }
    }

    public enum Level: String, Equatable { case model, family, prior }

    /// Multiplier for `model` and the level it came from.
    public func multiplier(for model: String) -> (value: Double, level: Level) {
        let family = Self.family(of: model)
        let prior = Self.prior(forFamily: family)
        if let scale = modelScales[model], scale.samples >= configuration.minimumSamples {
            return (prior * scale.value, .model)
        }
        if let scale = familyScales[family], scale.samples >= configuration.minimumSamples {
            return (prior * scale.value, .family)
        }
        return (prior, .prior)
    }

    /// Weighted token count before the model multiplier.
    public func rawUnits(for record: TranscriptUsageRecord) -> Double {
        Double(record.inputTokens) * configuration.inputWeight
            + Double(record.outputTokens) * configuration.outputWeight
            + Double(record.cacheCreationTokens) * configuration.cacheCreationWeight
            + Double(record.cacheReadTokens) * configuration.cacheReadWeight
    }

    /// EWMA update. `ratio` is observed/predicted cost; `shares` maps model to its share of the interval's units.
    public mutating func learn(ratio: Double, shares: [String: Double]) {
        let ratio = min(max(ratio, 0.25), 4)
        let alpha = configuration.learningRate
        var familyShares: [String: Double] = [:]
        for (model, share) in shares {
            familyShares[Self.family(of: model), default: 0] += share
            apply(&modelScales[model, default: Scale()], ratio: ratio, share: share, alpha: alpha)
        }
        for (family, share) in familyShares {
            apply(&familyScales[family, default: Scale()], ratio: ratio, share: share, alpha: alpha)
        }
    }

    private func apply(_ scale: inout Scale, ratio: Double, share: Double, alpha: Double) {
        scale.value *= 1 + alpha * share * (ratio - 1)
        scale.samples += 1
    }
}
