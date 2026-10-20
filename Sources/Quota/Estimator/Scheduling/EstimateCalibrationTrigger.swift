import Foundation

/// Tunables for estimate-driven calibration. Injected so tests and BB-01 central configuration can
/// override them; the defaults are the Issue's contract.
public struct EstimateCalibrationConfiguration: Equatable {
    /// Estimated rise (percentage points above the anchor) that justifies a read while the estimator
    /// is still learning.
    public var learningRisePoints = 2.0
    /// Estimated rise that justifies a read once the estimate is trustworthy.
    public var qualifiedRisePoints = 5.0
    /// Estimate confidence at or above which the estimator counts as qualified.
    public var qualifiedConfidence = 0.5
    /// A notification threshold counts as approached when the estimated remaining percentage is
    /// within this many points above it (or already below it).
    public var notificationApproachMarginPoints = 2.0
    /// Minimum estimated rise before an approached notification threshold triggers a read, so a
    /// fresh official value that merely sits near a threshold does not cause a request.
    public var notificationMinimumRisePoints = 1.0

    public init() {}
}

/// Why a calibration request was made.
public enum EstimateCalibrationCause: Equatable {
    /// The estimate rose by at least the learning-period step.
    case learningRise
    /// The estimate rose by at least the qualified step.
    case qualifiedRise
    /// The estimated remaining percentage approached a user notification threshold (remaining %).
    case notificationThreshold(Double)
}

/// Decides when an estimate is worth an official reading and asks the scheduler for one.
///
/// This type only *requests*: every read goes through `FetchScheduling.requestFetch(reason:)`, so
/// coalescing, the minimum interval, the token bucket, cooldown and the 401 pause stay the
/// scheduler's decision. The scheduler gives no feedback, so the trigger rate-limits itself: after
/// asking, the next request for the same window needs the estimate to rise by another full step, and
/// an official reading re-anchors the window. It never changes any displayed value.
///
/// Thread-safe; performs no IO.
public final class EstimateCalibrationTrigger {
    private struct Key: Hashable { let accountID: String; let window: QuotaWindowKind }

    private struct State {
        var anchorPercent: Double
        /// Estimate at the last request since this anchor; the next request needs a further rise.
        var lastRequestedPercent: Double?
    }

    private let scheduler: FetchScheduling
    private let configuration: EstimateCalibrationConfiguration
    private let notificationThresholds: (QuotaWindowKind) -> [Double]
    private let lock = NSLock()
    private var states: [Key: State] = [:]

    /// - Parameter notificationThresholds: Remaining-percentage thresholds the user's notification
    ///   rules use for a window. Empty disables the notification trigger.
    public init(
        scheduler: FetchScheduling,
        configuration: EstimateCalibrationConfiguration = EstimateCalibrationConfiguration(),
        notificationThresholds: @escaping (QuotaWindowKind) -> [Double] = { _ in [] }
    ) {
        self.scheduler = scheduler
        self.configuration = configuration
        self.notificationThresholds = notificationThresholds
    }

    /// Re-anchors a window on an official reading (used percentage) and re-arms the triggers.
    public func recordOfficial(accountID: String, window: QuotaWindowKind, percent: Double) {
        guard percent.isFinite else { return }
        lock.withLock {
            states[Key(accountID: accountID, window: window)] = State(anchorPercent: percent)
        }
    }

    /// Evaluates a fresh estimate and requests an official reading when it is worth one.
    /// Returns the cause when a request was made, `nil` otherwise.
    @discardableResult
    public func evaluate(accountID: String, window: QuotaWindowKind, estimate: UsageEstimate) -> EstimateCalibrationCause? {
        guard estimate.percent.isFinite, estimate.confidence.isFinite else { return nil }
        let key = Key(accountID: accountID, window: window)
        let thresholds = notificationThresholds(window)
        let cause: EstimateCalibrationCause? = lock.withLock {
            guard var state = states[key] else { return nil }
            let baseline = max(state.anchorPercent, state.lastRequestedPercent ?? state.anchorPercent)
            let rise = estimate.percent - baseline
            guard rise > 0 else { return nil }

            let qualified = estimate.confidence >= configuration.qualifiedConfidence
            let step = qualified ? configuration.qualifiedRisePoints : configuration.learningRisePoints
            var cause: EstimateCalibrationCause?
            if rise >= step {
                cause = qualified ? .qualifiedRise : .learningRise
            } else if rise >= configuration.notificationMinimumRisePoints,
                      let threshold = approachedThreshold(thresholds, anchor: state.anchorPercent, estimate: estimate.percent) {
                cause = .notificationThreshold(threshold)
            }
            guard cause != nil else { return nil }
            state.lastRequestedPercent = estimate.percent
            states[key] = state
            return cause
        }
        // Outside the lock: the scheduler hops to its own queue, but never hold ours across callers.
        if cause != nil { scheduler.requestFetch(reason: .estimatedCalibration) }
        return cause
    }

    /// The most urgent (lowest) threshold the estimate has reached or come within the margin of
    /// that the official anchor has not already crossed.
    private func approachedThreshold(_ thresholds: [Double], anchor: Double, estimate: Double) -> Double? {
        let anchorRemaining = 100 - anchor
        let estimatedRemaining = 100 - estimate
        return thresholds
            .filter { $0.isFinite && anchorRemaining > $0 && estimatedRemaining <= $0 + configuration.notificationApproachMarginPoints }
            .min()
    }
}
