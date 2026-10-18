import Foundation

/// One accepted observation of a quota window, stored without credentials.
public struct QuotaMergedReading: Codable, Equatable {
    /// Percentage already used.
    public let usedPercentage: Double

    /// Absolute reset time reported by the source, when known.
    public let resetsAt: Date?

    /// Source-side observation time, when known.
    public let observedAt: Date?

    /// Local receipt time.
    public let receivedAt: Date

    /// Stable source identifier.
    public let source: String

    /// Trust grade of the accepted observation.
    public let trust: QuotaTrust

    /// Account generation captured with the observation.
    public let epoch: AccountEpoch

    init(_ observation: QuotaObservation) {
        usedPercentage = observation.usedPercentage
        resetsAt = observation.resetsAt
        observedAt = observation.observedAt
        receivedAt = observation.receivedAt
        source = observation.source
        trust = observation.trust
        epoch = observation.epoch
    }

    /// Time used to order readings: the source time, falling back to receipt time.
    var effectiveTime: Date { observedAt ?? receivedAt }
}

/// Merge state for one quota window of one account.
public struct QuotaMergedWindow: Codable, Equatable {
    /// Currently displayed reading.
    public var displayed: QuotaMergedReading?

    /// Latest grade-A reading in the current epoch, used to admit grade-B readings.
    public var latestGradeA: QuotaMergedReading?

    /// Reset time of the cycle that passed and awaits confirmation, when pending.
    public var pendingResetOf: Date?
}

/// Persisted merge-engine state, keyed by stable account ID and window.
public struct QuotaMergeState: Codable, Equatable {
    /// Account generation the state belongs to.
    public var epoch: AccountEpoch

    /// Stable ID of the active account, when known.
    public var accountID: String?

    /// Per-window state keyed by `QuotaWindowKind.rawValue`.
    public var windows: [String: QuotaMergedWindow]

    /// Creates empty or restored state.
    public init(epoch: AccountEpoch = .initial, accountID: String? = nil, windows: [String: QuotaMergedWindow] = [:]) {
        self.epoch = epoch
        self.accountID = accountID
        self.windows = windows
    }
}

/// Storage boundary for merge-engine results.
public protocol QuotaMergeStateStoring {
    /// Loads previously saved state, or `nil` when none is usable.
    func load() -> QuotaMergeState?

    /// Saves state; implementations must not block the caller on disk IO.
    func save(_ state: QuotaMergeState)
}

/// JSON file store that writes on a private background queue.
public final class QuotaMergeFileStore: QuotaMergeStateStoring {
    private let url: URL
    private let queue = DispatchQueue(label: "BalanceBar.QuotaMergeFileStore", qos: .utility)

    /// Creates a store backed by the given file URL.
    public init(url: URL) {
        self.url = url
    }

    public func load() -> QuotaMergeState? {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(QuotaMergeState.self, from: data)
        }
    }

    public func save(_ state: QuotaMergeState) {
        let url = url
        queue.async {
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Blocks until queued writes finish; intended for tests and shutdown.
    public func flush() {
        queue.sync {}
    }
}

/// Reserved input for the estimator (BB-16); returns no estimate in this version.
public protocol QuotaEstimationProviding {
    /// Returns an estimated reading for a window at `date`, or `nil` when none is available.
    func estimatedReading(for window: QuotaWindowKind, current: QuotaMergedWindow, at date: Date) -> QuotaMergedReading?
}

/// Reserved input for drift detection (BB-18); receives accepted observations.
public protocol QuotaDriftDetecting {
    /// Called after an observation was accepted with the previous displayed reading.
    func didAccept(_ observation: QuotaObservation, previous: QuotaMergedReading?)
}

/// Placeholder estimator that never produces an estimate.
public struct NoQuotaEstimation: QuotaEstimationProviding {
    public init() {}

    public func estimatedReading(for window: QuotaWindowKind, current: QuotaMergedWindow, at date: Date) -> QuotaMergedReading? {
        nil
    }
}

/// Placeholder drift detector that ignores all input.
public struct NoQuotaDriftDetection: QuotaDriftDetecting {
    public init() {}

    public func didAccept(_ observation: QuotaObservation, previous: QuotaMergedReading?) {}
}

/// The single owner of quota display state; merges observations into `QuotaDisplayModel`.
public final class QuotaMergeEngine: QuotaMerging {
    private let lock = NSLock()
    private var state: QuotaMergeState
    private let store: QuotaMergeStateStoring?
    private let scheduler: FetchScheduling
    private let notifications: QuotaNotificationSink?
    private let estimation: QuotaEstimationProviding
    private let drift: QuotaDriftDetecting
    private let now: () -> Date

    /// Windows that always appear in the display model, even without data.
    static let baseWindows: [QuotaWindowKind] = [.fiveHour, .sevenDay]

    /// Creates an engine, restoring cached state from `store` when available.
    public init(
        scheduler: FetchScheduling,
        notifications: QuotaNotificationSink? = nil,
        store: QuotaMergeStateStoring? = nil,
        estimation: QuotaEstimationProviding = NoQuotaEstimation(),
        drift: QuotaDriftDetecting = NoQuotaDriftDetection(),
        now: @escaping () -> Date = Date.init
    ) {
        self.scheduler = scheduler
        self.notifications = notifications
        self.store = store
        self.estimation = estimation
        self.drift = drift
        self.now = now
        state = store?.load() ?? QuotaMergeState()
    }

    /// Current display model without merging new input.
    public var displayModel: QuotaDisplayModel {
        lock.lock()
        defer { lock.unlock() }
        return makeDisplayModel()
    }

    /// Snapshot of the internal state, for diagnostics and tests.
    public var currentState: QuotaMergeState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    @discardableResult
    public func merge(_ observation: QuotaObservation) -> QuotaDisplayModel {
        var events: [QuotaNotificationEvent] = []
        var requestConfirmation = false
        let model: QuotaDisplayModel
        lock.lock()
        requestConfirmation = advanceClock()
        let accepted = accept(observation, events: &events)
        if accepted || requestConfirmation {
            store?.save(state)
        }
        model = makeDisplayModel()
        lock.unlock()
        if requestConfirmation { scheduler.requestFetch(reason: .resetConfirmation) }
        events.forEach { notifications?.publish($0) }
        return model
    }

    /// Re-evaluates reset deadlines against the clock; call on timer ticks.
    @discardableResult
    public func refresh() -> QuotaDisplayModel {
        lock.lock()
        let requestConfirmation = advanceClock()
        if requestConfirmation { store?.save(state) }
        let model = makeDisplayModel()
        lock.unlock()
        if requestConfirmation { scheduler.requestFetch(reason: .resetConfirmation) }
        return model
    }

    /// Responds to an account switch: clears the old account's data and grade-B state.
    @discardableResult
    public func accountDidChange(epoch: AccountEpoch, accountID: String?) -> QuotaDisplayModel {
        lock.lock()
        if epoch > state.epoch || accountID != state.accountID {
            state = QuotaMergeState(epoch: max(epoch, state.epoch), accountID: accountID)
            store?.save(state)
        }
        let model = makeDisplayModel()
        lock.unlock()
        return model
    }

    // MARK: - Rules (called with `lock` held)

    /// Moves windows past their reset time into pending confirmation; returns whether to request a read.
    private func advanceClock() -> Bool {
        let date = now()
        var changed = false
        for (key, var window) in state.windows {
            guard window.pendingResetOf == nil,
                  let resetsAt = window.displayed?.resetsAt,
                  resetsAt <= date else { continue }
            window.pendingResetOf = resetsAt
            state.windows[key] = window
            changed = true
        }
        return changed
    }

    private func accept(_ observation: QuotaObservation, events: inout [QuotaNotificationEvent]) -> Bool {
        if observation.epoch < state.epoch { return false }
        if observation.epoch > state.epoch {
            state = QuotaMergeState(epoch: observation.epoch, accountID: observation.accountID)
        } else if state.accountID == nil {
            state.accountID = observation.accountID
        } else if state.accountID != observation.accountID {
            return false
        }

        let key = observation.window.rawValue
        var window = state.windows[key] ?? QuotaMergedWindow()
        let reading = QuotaMergedReading(observation)

        if let pending = window.pendingResetOf {
            // Only a grade-A reading of the next cycle confirms the reset.
            guard observation.trust == .a, isNextCycle(reading, after: pending) else { return false }
            window = QuotaMergedWindow(displayed: reading, latestGradeA: reading, pendingResetOf: nil)
            state.windows[key] = window
            events.append(.resetConfirmed(window: observation.window))
            drift.didAccept(observation, previous: nil)
            return true
        }

        if let displayed = window.displayed, reading.effectiveTime < displayed.effectiveTime {
            return false
        }

        switch observation.trust {
        case .a:
            let previous = window.displayed
            window.latestGradeA = reading
            window.displayed = reading
            state.windows[key] = window
            drift.didAccept(observation, previous: previous)
            return true
        case .b:
            guard let gradeA = window.latestGradeA,
                  gradeA.epoch == observation.epoch,
                  reading.usedPercentage >= gradeA.usedPercentage - QuotaConstants.gradeBTolerancePercentagePoints,
                  sameCycle(reading.resetsAt, gradeA.resetsAt) else { return false }
            let previous = window.displayed
            window.displayed = reading
            state.windows[key] = window
            drift.didAccept(observation, previous: previous)
            return true
        }
    }

    private func isNextCycle(_ reading: QuotaMergedReading, after pending: Date) -> Bool {
        if let resetsAt = reading.resetsAt { return resetsAt > pending }
        // A fresh window that has not started reports zero use without a reset time.
        return reading.usedPercentage == 0
    }

    private func sameCycle(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l.timeIntervalSince1970.rounded() == r.timeIntervalSince1970.rounded()
        default: return false
        }
    }

    private func makeDisplayModel() -> QuotaDisplayModel {
        let date = now()
        var kinds = Self.baseWindows
        for key in state.windows.keys.sorted() {
            let kind = QuotaWindowKind(rawValue: key)
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        let windows = kinds.map { kind -> QuotaWindowDisplay in
            let window = state.windows[kind.rawValue] ?? QuotaMergedWindow()
            let estimate = estimation.estimatedReading(for: kind, current: window, at: date)
            guard let reading = estimate ?? window.displayed else {
                return QuotaWindowDisplay(kind: kind, usedPercentage: nil, isEstimated: false,
                                          state: .noData, hoverTextKey: Self.hoverKey(.noData))
            }
            let windowState: WindowState
            if window.pendingResetOf != nil {
                windowState = .resetPendingConfirmation
            } else if reading.usedPercentage == 0, reading.resetsAt == nil {
                windowState = .notStarted
            } else {
                windowState = .inProgress
            }
            return QuotaWindowDisplay(kind: kind, usedPercentage: reading.usedPercentage,
                                      resetsAt: reading.resetsAt, isEstimated: estimate != nil,
                                      state: windowState, hoverTextKey: Self.hoverKey(windowState))
        }
        let aggregate = Self.aggregateState(windows.map(\.state))
        return QuotaDisplayModel(windows: windows, isEstimated: windows.contains { $0.isEstimated },
                                 state: aggregate, hoverTextKey: Self.hoverKey(aggregate))
    }

    static func aggregateState(_ states: [WindowState]) -> WindowState {
        for candidate in [WindowState.error, .resetPendingConfirmation, .inProgress, .notStarted, .expired]
            where states.contains(candidate) {
            return candidate
        }
        return .noData
    }

    static func hoverKey(_ state: WindowState) -> String {
        "quota.merge.hover.\(state.rawValue)"
    }
}
