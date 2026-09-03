import AppKit

/// The monitor result is deliberately more precise than the legacy
/// `isTaskRunning` Boolean. A missing activity sample is not proof that a
/// task ended, while a lifecycle terminal is strong enough to end it
/// immediately. Context compaction is kept separate so it can keep a task
/// alive without adding another timer.
enum ActivityMonitorObservation: Equatable {
    case active
    case ambiguousIdle
    case hardTerminal
    case contextCompaction

    var isActiveEvidence: Bool {
        switch self {
        case .active, .contextCompaction:
            return true
        case .ambiguousIdle, .hardTerminal:
            return false
        }
    }

    /// Preserves the old monitor Boolean semantics. Context compaction by
    /// itself was historically not reported as running until explicit
    /// follow-up activity appeared; the coordinator can still use it as
    /// lifecycle evidence.
    var legacyIsTaskRunning: Bool {
        self == .active
    }
}

/// Stabilizes one provider's raw monitor evidence before it reaches the
/// application state and its refresh/render side effects.
struct ActivityLifecycleStateMachine {
    static let activationConfirmationInterval: TimeInterval = 0.5
    static let ambiguousIdleGraceInterval: TimeInterval = 10
    private static let minimumActivationSamples = 2

    private enum PendingTransitionKind: Equatable {
        case activation
        case ambiguousIdle
    }

    private struct PendingTransition {
        let kind: PendingTransitionKind
        let startedAt: Date
        var lastSampleAt: Date
        var sampleCount: Int
    }

    private(set) var isRunning = false
    private var pendingTransition: PendingTransition?
    private var expectedSampleInterval: TimeInterval = 0.25

    mutating func updateSampleInterval(_ interval: TimeInterval) {
        guard interval.isFinite, interval > 0 else { return }
        expectedSampleInterval = interval
    }

    /// Ingest one monitor observation and return the stable lifecycle state.
    /// This method has no timer: a transition can only be committed by a
    /// subsequent monitor sample.
    @discardableResult
    mutating func observe(
        _ observation: ActivityMonitorObservation,
        at date: Date
    ) -> Bool {
        switch observation {
        case .active, .contextCompaction:
            if isRunning {
                pendingTransition = nil
                return true
            }

            if var pending = pendingTransition,
               pending.kind == .activation,
               date > pending.lastSampleAt,
               date.timeIntervalSince(pending.lastSampleAt) <= maximumActivationSampleGap {
                pending.lastSampleAt = date
                pending.sampleCount += 1
                pendingTransition = pending
            } else {
                pendingTransition = PendingTransition(
                    kind: .activation,
                    startedAt: date,
                    lastSampleAt: date,
                    sampleCount: 1
                )
            }

            if let pendingTransition,
               pendingTransition.kind == .activation,
               pendingTransition.sampleCount >= Self.minimumActivationSamples,
               date.timeIntervalSince(pendingTransition.startedAt)
                    >= Self.activationConfirmationInterval {
                isRunning = true
                self.pendingTransition = nil
            }

        case .hardTerminal:
            pendingTransition = nil
            isRunning = false

        case .ambiguousIdle:
            guard isRunning else {
                pendingTransition = nil
                return false
            }

            if var pending = pendingTransition,
               pending.kind == .ambiguousIdle {
                // The grace window is elapsed-time based. A delayed sample
                // still confirms that the raw state remained idle for the
                // whole observed interval; no fixed sample count is used.
                pending.lastSampleAt = max(pending.lastSampleAt, date)
                pendingTransition = pending
            } else {
                pendingTransition = PendingTransition(
                    kind: .ambiguousIdle,
                    startedAt: date,
                    lastSampleAt: date,
                    sampleCount: 1
                )
            }

            if let pendingTransition,
               pendingTransition.kind == .ambiguousIdle,
               date.timeIntervalSince(pendingTransition.startedAt)
                    >= Self.ambiguousIdleGraceInterval {
                isRunning = false
                self.pendingTransition = nil
            }
        }
        return isRunning
    }

    /// A provider/client switch invalidates an unconfirmed candidate without
    /// changing its already committed lifecycle state.
    mutating func clearPendingTransition() {
        pendingTransition = nil
    }

    /// Reset all lifecycle state at a monitor stop/restart boundary.
    @discardableResult
    mutating func reset() -> Bool {
        let wasRunning = isRunning
        isRunning = false
        pendingTransition = nil
        return wasRunning
    }

    private var maximumActivationSampleGap: TimeInterval {
        // Permit the supported 0.25/0.5/1.0 second polling choices while
        // preventing a stale candidate from combining unrelated samples.
        max(1, expectedSampleInterval * 2.5)
    }
}

struct ActivityCoordinatorActions {
    let activeClient: () -> AssistantClient
    let claudeProcessAvailable: () -> Bool
    let setClaudeProcessAvailable: (Bool) -> Void
    let setActiveClient: (AssistantClient) -> Void
    let setCodexTaskRunning: (Bool) -> Void
    let setClaudeTaskRunning: (Bool) -> Void
}

/// Owns activity polling, frontmost-app observation, and the two accepted
/// activity monitors. It emits values; refresh/render policy remains in the
/// application composition root.
final class ActivityCoordinator {
    private let codexMonitor: CodexActivityMonitor
    private let claudeMonitor: ClaudeCodeActivityMonitor
    private let queue: DispatchQueue
    private let actions: ActivityCoordinatorActions
    private var pollTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var isCheckInFlight = false
    private var isStarted = false
    private var lifecycleGeneration: UInt64 = 0
    private var lastSampledClient: AssistantClient?
    private var codexLifecycle = ActivityLifecycleStateMachine()
    private var claudeLifecycle = ActivityLifecycleStateMachine()

    private(set) var startCount = 0

    init(
        codexMonitor: CodexActivityMonitor = CodexActivityMonitor(),
        claudeMonitor: ClaudeCodeActivityMonitor = ClaudeCodeActivityMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.activity-monitor", qos: .utility),
        actions: ActivityCoordinatorActions
    ) {
        self.codexMonitor = codexMonitor
        self.claudeMonitor = claudeMonitor
        self.queue = queue
        self.actions = actions
    }

    func start(interval: TimeInterval) {
        guard !isStarted else { return }
        isStarted = true
        lifecycleGeneration &+= 1
        codexLifecycle.updateSampleInterval(interval)
        claudeLifecycle.updateSampleInterval(interval)
        startCount += 1
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.handleFrontmostApplicationChange() }
        configureTimer(interval: interval)
    }

    func updateInterval(_ interval: TimeInterval) {
        guard isStarted else { return }
        codexLifecycle.updateSampleInterval(interval)
        claudeLifecycle.updateSampleInterval(interval)
        configureTimer(interval: interval)
    }

    func stop() {
        let wasStarted = isStarted
        pollTimer?.invalidate()
        pollTimer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        isStarted = false
        isCheckInFlight = false
        lifecycleGeneration &+= 1
        lastSampledClient = nil
        let codexWasRunning = codexLifecycle.reset()
        let claudeWasRunning = claudeLifecycle.reset()
        if wasStarted {
            if codexWasRunning { actions.setCodexTaskRunning(false) }
            if claudeWasRunning { actions.setClaudeTaskRunning(false) }
        }
    }

    func pollNow() {
        guard isStarted else { return }
        refreshActivity()
    }

    private func configureTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshActivity()
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleFrontmostApplicationChange() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if Self.isCodexApplication(frontmost) {
            actions.setActiveClient(.codex)
        } else if Self.isTerminalApplication(frontmost) {
            if actions.claudeProcessAvailable() {
                actions.setActiveClient(.claude)
            } else {
                refreshActivity()
            }
        }
    }

    private func refreshActivity() {
        guard isStarted else { return }
        handleFrontmostApplicationChangeWithoutRefresh()
        guard !isCheckInFlight else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostIsCodex = Self.isCodexApplication(frontmost)
        let frontmostIsTerminal = Self.isTerminalApplication(frontmost)
        let clientBeforeCheck = actions.activeClient()
        let sampledClient: AssistantClient = frontmostIsCodex
            ? .codex
            : frontmostIsTerminal
                ? .claude
                : clientBeforeCheck
        if sampledClient != lastSampledClient {
            codexLifecycle.clearPendingTransition()
            claudeLifecycle.clearPendingTransition()
            lastSampledClient = sampledClient
        }
        let generation = lifecycleGeneration
        isCheckInFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            var codexObservation: ActivityMonitorObservation?
            var claudeStatus: (processRunning: Bool, observation: ActivityMonitorObservation)?
            if frontmostIsCodex {
                codexObservation = self.codexMonitor.activityObservation()
            } else if frontmostIsTerminal {
                let status = self.claudeMonitor.activityStatus()
                claudeStatus = status
                if !status.processRunning {
                    codexObservation = self.codexMonitor.activityObservation()
                }
            } else if clientBeforeCheck == .codex {
                codexObservation = self.codexMonitor.activityObservation()
            } else {
                claudeStatus = self.claudeMonitor.activityStatus()
            }
            let sampledAt = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isStarted, self.lifecycleGeneration == generation else { return }
                self.isCheckInFlight = false
                if let claudeStatus {
                    if self.actions.claudeProcessAvailable() != claudeStatus.processRunning {
                        self.actions.setClaudeProcessAvailable(claudeStatus.processRunning)
                    }
                }
                let currentFrontmost = NSWorkspace.shared.frontmostApplication
                if Self.isCodexApplication(currentFrontmost) {
                    self.actions.setActiveClient(.codex)
                } else if Self.isTerminalApplication(currentFrontmost),
                          claudeStatus?.processRunning == true {
                    self.actions.setActiveClient(.claude)
                }
                if let codexObservation {
                    let stableState = self.codexLifecycle.observe(codexObservation, at: sampledAt)
                    self.actions.setCodexTaskRunning(stableState)
                }
                if let claudeStatus {
                    let stableState = self.claudeLifecycle.observe(claudeStatus.observation, at: sampledAt)
                    self.actions.setClaudeTaskRunning(stableState)
                }
            }
        }
    }

    private func handleFrontmostApplicationChangeWithoutRefresh() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if Self.isCodexApplication(frontmost) {
            actions.setActiveClient(.codex)
        } else if Self.isTerminalApplication(frontmost),
                  actions.claudeProcessAvailable() {
            actions.setActiveClient(.claude)
        }
    }

    private static func isCodexApplication(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        let identifier = (application.bundleIdentifier ?? "").lowercased()
        let name = (application.localizedName ?? "").lowercased()
        if name == "codex" { return true }
        return identifier == "com.openai.codex"
            || (identifier.contains("codex") && !identifier.contains("codexbar"))
    }

    private static func isTerminalApplication(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        let identifier = (application.bundleIdentifier ?? "").lowercased()
        let name = (application.localizedName ?? "").lowercased()
        let knownIdentifiers = [
            "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
            "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
            "com.github.wez.wezterm", "co.zeit.hyper"
        ]
        if knownIdentifiers.contains(identifier) { return true }
        return ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm"]
            .contains(where: { name.contains($0) })
    }

    deinit { stop() }
}
