import Foundation

/// Tunable values for multi-device compensation.
///
/// Not yet in `QuotaConstants`; candidates for promotion there.
public struct MultiDeviceCompensationConfiguration: Equatable {
    /// Official increase beyond local growth, in percentage points, that signals other-device use.
    public var driftThresholdPercentagePoints: Double = 3
    /// Interval between fetch requests while external-active mode is on.
    public var externalActiveRequestInterval: TimeInterval = 5 * 60
    /// Maximum length of one external-active period.
    public var externalActiveDuration: TimeInterval = 30 * 60
    /// Consecutive requests without any official change that end external-active mode.
    public var unchangedRequestsToExit: Int = 2
    /// Delay between Claude Desktop leaving the foreground and the fetch request.
    public var desktopSwitchAwayDelay: TimeInterval = 5
    /// Longest an official value may age before a calibration request.
    public var calibrationIntervalLimit: TimeInterval = 30 * 60
    /// Bundle identifier of Claude Desktop.
    public var desktopBundleIdentifier: String = "com.anthropic.claudefordesktop"

    public init() {}
}

/// Local-only usage growth used to tell this device's usage from other devices' usage.
public protocol LocalUsageGrowthEstimating {
    /// Estimated percentage points of `window` consumed locally between `start` and `end`,
    /// or `nil` when unknown (drift detection is then skipped).
    func estimatedLocalGrowth(for window: QuotaWindowKind, from start: Date, to end: Date) -> Double?
}

/// Defers work; tests inject a manual timer. Mirrors the scheduler's timer contract.
public protocol MultiDeviceTimer {
    /// Runs `work` once after `delay` seconds on an unspecified queue.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

/// `DispatchQueue`-backed `MultiDeviceTimer`.
public struct DispatchMultiDeviceTimer: MultiDeviceTimer {
    private let queue: DispatchQueue
    public init(queue: DispatchQueue = .global(qos: .utility)) { self.queue = queue }
    public func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }
}

/// Requests fetches when usage on other devices (web, Claude Desktop) is likely.
///
/// Every trigger goes through `FetchScheduling.requestFetch(reason:)`; the scheduler keeps
/// budget and cooldown authority. Official values are the grade-A observations delivered
/// through `QuotaDriftDetecting`.
public final class MultiDeviceCompensator: QuotaDriftDetecting {
    private let scheduler: FetchScheduling
    private let localGrowth: LocalUsageGrowthEstimating?
    private let timer: MultiDeviceTimer
    private let now: () -> Date
    private let configuration: MultiDeviceCompensationConfiguration

    private let lock = NSLock()
    private var latestOfficial: [String: Double] = [:]
    /// Previous grade-A reading per window; the displayed reading may be grade B and is not an official baseline.
    private var officialBaseline: [String: (accountID: String, reading: QuotaMergedReading)] = [:]
    private var lastOfficialAt: Date?
    private var calibrationGeneration = 0

    private var isExternalActive = false
    private var externalActiveStart = Date.distantPast
    private var externalActiveGeneration = 0
    private var snapshotAtLastRequest: [String: Double]?
    private var unchangedRequests = 0

    private var isDesktopForeground = false
    private var desktopSwitchGeneration = 0

    public init(
        scheduler: FetchScheduling,
        localGrowth: LocalUsageGrowthEstimating? = nil,
        timer: MultiDeviceTimer = DispatchMultiDeviceTimer(),
        now: @escaping () -> Date = Date.init,
        configuration: MultiDeviceCompensationConfiguration = MultiDeviceCompensationConfiguration()
    ) {
        self.scheduler = scheduler
        self.localGrowth = localGrowth
        self.timer = timer
        self.now = now
        self.configuration = configuration
    }

    /// Whether external-active mode is currently on (diagnostics and tests).
    public var externalActiveModeIsOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isExternalActive
    }

    // MARK: - Official values and drift

    public func didAccept(_ observation: QuotaObservation, previous: QuotaMergedReading?) {
        guard observation.trust == .a else { return }
        lock.lock()
        let key = observation.window.rawValue
        // A baseline from another account must never be compared against this account's value.
        let cached = officialBaseline[key].flatMap { $0.accountID == observation.accountID ? $0.reading : nil }
        let baseline = cached ?? (previous?.trust == .a ? previous : nil)
        officialBaseline[key] = (observation.accountID, QuotaMergedReading(observation))
        latestOfficial[key] = observation.usedPercentage
        lastOfficialAt = observation.receivedAt
        let driftDetected = detectsDrift(observation, baseline: baseline)
        var startChain = false
        if driftDetected {
            startChain = !isExternalActive
            isExternalActive = true
            externalActiveStart = now()
            unchangedRequests = 0
            snapshotAtLastRequest = nil
            if startChain { externalActiveGeneration += 1 }
        }
        calibrationGeneration += 1
        let calibration = calibrationGeneration
        let external = externalActiveGeneration
        lock.unlock()

        scheduleCalibrationCheck(generation: calibration)
        if startChain { scheduleExternalActiveTick(generation: external) }
    }

    private func detectsDrift(_ observation: QuotaObservation, baseline previous: QuotaMergedReading?) -> Bool {
        guard let previous, let localGrowth,
              previous.epoch == observation.epoch,
              Self.sameCycle(previous.resetsAt, observation.resetsAt) else { return false }
        let officialGrowth = observation.usedPercentage - previous.usedPercentage
        guard officialGrowth > 0,
              let local = localGrowth.estimatedLocalGrowth(
                for: observation.window, from: previous.receivedAt, to: observation.receivedAt)
        else { return false }
        return officialGrowth - max(0, local) >= configuration.driftThresholdPercentagePoints
    }

    private static func sameCycle(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l.timeIntervalSince1970.rounded() == r.timeIntervalSince1970.rounded()
        default: return false
        }
    }

    // MARK: - External-active mode

    private func scheduleExternalActiveTick(generation: Int) {
        timer.schedule(after: configuration.externalActiveRequestInterval) { [weak self] in
            self?.externalActiveTick(generation: generation)
        }
    }

    private func externalActiveTick(generation: Int) {
        lock.lock()
        guard isExternalActive, generation == externalActiveGeneration else {
            lock.unlock()
            return
        }
        if let snapshot = snapshotAtLastRequest {
            unchangedRequests = snapshot == latestOfficial ? unchangedRequests + 1 : 0
        }
        let expired = now().timeIntervalSince(externalActiveStart) >= configuration.externalActiveDuration
        if expired || unchangedRequests >= configuration.unchangedRequestsToExit {
            isExternalActive = false
            externalActiveGeneration += 1
            snapshotAtLastRequest = nil
            lock.unlock()
            return
        }
        snapshotAtLastRequest = latestOfficial
        lock.unlock()

        scheduler.requestFetch(reason: .externalActivity)
        scheduleExternalActiveTick(generation: generation)
    }

    // MARK: - Claude Desktop foreground changes

    /// Reports the frontmost application's bundle identifier.
    ///
    /// Leaving Claude Desktop requests a fetch after `desktopSwitchAwayDelay`; returning to it
    /// within that delay cancels the request.
    public func foregroundApplicationDidChange(bundleIdentifier: String?) {
        let isDesktop = bundleIdentifier == configuration.desktopBundleIdentifier
        lock.lock()
        let wasDesktop = isDesktopForeground
        isDesktopForeground = isDesktop
        // Only Desktop entering or leaving the foreground invalidates a pending request;
        // switches between other apps must not cancel it.
        if wasDesktop != isDesktop { desktopSwitchGeneration += 1 }
        let generation = desktopSwitchGeneration
        let leftDesktop = wasDesktop && !isDesktop
        lock.unlock()

        guard leftDesktop else { return }
        timer.schedule(after: configuration.desktopSwitchAwayDelay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = generation == self.desktopSwitchGeneration
            self.lock.unlock()
            if valid { self.scheduler.requestFetch(reason: .externalActivity) }
        }
    }

    // MARK: - Calibration limit

    private func scheduleCalibrationCheck(generation: Int) {
        timer.schedule(after: configuration.calibrationIntervalLimit) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = generation == self.calibrationGeneration
            let due = valid && (self.lastOfficialAt.map {
                self.now().timeIntervalSince($0) >= self.configuration.calibrationIntervalLimit
            } ?? false)
            self.lock.unlock()
            guard valid else { return }
            if due { self.scheduler.requestFetch(reason: .estimatedCalibration) }
            self.scheduleCalibrationCheck(generation: generation)
        }
    }
}

#if canImport(AppKit)
import AppKit

/// Feeds frontmost-application changes to a compensator using `NSWorkspace` notifications.
/// Needs no system permission.
public final class WorkspaceForegroundApplicationMonitor {
    private var token: NSObjectProtocol?

    public init() {}

    /// Starts observing; replaces any previous observation. The current frontmost
    /// application is reported immediately so a later switch away is recognized.
    public func start(_ handler: @escaping (String?) -> Void) {
        stop()
        handler(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            handler(app?.bundleIdentifier)
        }
    }

    public func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    deinit { stop() }
}
#endif
