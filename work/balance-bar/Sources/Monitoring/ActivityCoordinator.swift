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

struct ActivityLifecycleUpdate: Equatable {
    let taskRunning: Bool
    let observation: ActivityMonitorObservation
    let trailingRefreshAnchor: Date?
}

enum ActivityRefreshPhase: Equatable {
    case inactive
    case normalActive
    case suspended
}

/// Tracks the refresh-side phase independently from the task lifecycle. A
/// suspended phase keeps the task UI alive but does not authorize normal
/// active-duty refreshes. Ambiguous idle may retain a trailing anchor; active
/// work and compaction explicitly cancel that potential end.
struct ActivityRefreshLifecycle {
    private(set) var phase: ActivityRefreshPhase = .inactive
    private(set) var trailingRefreshAnchor: Date?
    private var immediateResumePending = false

    mutating func apply(_ update: ActivityLifecycleUpdate) {
        let previousPhase = phase
        switch update.observation {
        case .active:
            phase = update.taskRunning ? .normalActive : .inactive
            trailingRefreshAnchor = nil
        case .contextCompaction:
            phase = update.taskRunning ? .suspended : .inactive
            trailingRefreshAnchor = nil
        case .ambiguousIdle:
            phase = update.taskRunning ? .suspended : .inactive
            if let anchor = update.trailingRefreshAnchor {
                trailingRefreshAnchor = earliestDate(trailingRefreshAnchor, anchor)
            }
        case .hardTerminal:
            phase = .inactive
            if let anchor = update.trailingRefreshAnchor {
                trailingRefreshAnchor = earliestDate(trailingRefreshAnchor, anchor)
            }
        }

        if previousPhase == .suspended, phase == .normalActive {
            immediateResumePending = true
        } else if phase != .normalActive {
            immediateResumePending = false
        }
    }

    mutating func consumeImmediateResume() -> Bool {
        let pending = immediateResumePending
        immediateResumePending = false
        return pending
    }

    mutating func clearTrailingRefreshAnchor() {
        trailingRefreshAnchor = nil
    }

    mutating func reset() {
        phase = .inactive
        trailingRefreshAnchor = nil
        immediateResumePending = false
    }

    func trailingRefreshDeadline(duration: TimeInterval) -> Date? {
        guard duration > 0, let trailingRefreshAnchor else { return nil }
        return trailingRefreshAnchor.addingTimeInterval(duration)
    }

    private func earliestDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }
}

enum ActivityRefreshPolicy {
    static func shouldRefreshUsage(
        taskRunning: Bool,
        wasTaskRunning: Bool,
        phase: ActivityRefreshPhase,
        inTrailingWindow: Bool
    ) -> Bool {
        let stateChanged = taskRunning != wasTaskRunning
        let normalActive = taskRunning && phase == .normalActive
        return normalActive || inTrailingWindow || (stateChanged && !taskRunning)
    }

    static func shouldIssueRefresh(
        taskRunning: Bool,
        wasTaskRunning: Bool,
        phase: ActivityRefreshPhase,
        inTrailingWindow: Bool,
        now: Date,
        lastRefresh: Date?,
        refreshInterval: TimeInterval,
        resumed: Bool
    ) -> Bool {
        guard shouldRefreshUsage(
            taskRunning: taskRunning,
            wasTaskRunning: wasTaskRunning,
            phase: phase,
            inTrailingWindow: inTrailingWindow
        ) else {
            return false
        }
        let stateChanged = taskRunning != wasTaskRunning
        let refreshIsDue = lastRefresh.map {
            now.timeIntervalSince($0) >= refreshInterval
        } ?? true
        return stateChanged || resumed || refreshIsDue
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
        observeUpdate(observation, at: date).taskRunning
    }

    /// Ingest one monitor observation and retain the evidence needed by both
    /// the task UI and the independent activity-refresh lifecycle.
    @discardableResult
    mutating func observeUpdate(
        _ observation: ActivityMonitorObservation,
        at date: Date
    ) -> ActivityLifecycleUpdate {
        switch observation {
        case .active, .contextCompaction:
            if isRunning {
                pendingTransition = nil
                return makeUpdate(observation, trailingRefreshAnchor: nil)
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

            return makeUpdate(observation, trailingRefreshAnchor: nil)

        case .hardTerminal:
            let trailingRefreshAnchor: Date?
            if isRunning {
                if let pendingTransition,
                   pendingTransition.kind == .ambiguousIdle {
                    trailingRefreshAnchor = pendingTransition.startedAt
                } else {
                    trailingRefreshAnchor = date
                }
            } else {
                trailingRefreshAnchor = nil
            }
            pendingTransition = nil
            isRunning = false
            return makeUpdate(
                observation,
                trailingRefreshAnchor: trailingRefreshAnchor
            )

        case .ambiguousIdle:
            guard isRunning else {
                pendingTransition = nil
                return makeUpdate(observation, trailingRefreshAnchor: nil)
            }

            let trailingRefreshAnchor: Date
            if var pending = pendingTransition,
               pending.kind == .ambiguousIdle {
                trailingRefreshAnchor = pending.startedAt
                // The grace window is elapsed-time based. A delayed sample
                // still confirms that the raw state remained idle for the
                // whole observed interval; no fixed sample count is used.
                pending.lastSampleAt = max(pending.lastSampleAt, date)
                pendingTransition = pending
            } else {
                trailingRefreshAnchor = date
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
            return makeUpdate(
                observation,
                trailingRefreshAnchor: trailingRefreshAnchor
            )
        }
    }

    private func makeUpdate(
        _ observation: ActivityMonitorObservation,
        trailingRefreshAnchor: Date?
    ) -> ActivityLifecycleUpdate {
        ActivityLifecycleUpdate(
            taskRunning: isRunning,
            observation: observation,
            trailingRefreshAnchor: trailingRefreshAnchor
        )
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

enum ActivityFrontmostKind: Equatable {
    case codex
    case terminal
    case other
}

enum ActivityClientSelection {
    /// Chooses the menu-bar client from frontmost-app evidence and terminal
    /// process presence. Background Grok/Claude processes never steal Codex.
    static func client(
        frontmost: ActivityFrontmostKind,
        current: AssistantClient,
        grokProcessRunning: Bool,
        claudeProcessRunning: Bool,
        frontmostTTY: String? = nil,
        grokTTYs: Set<String> = [],
        claudeTTYs: Set<String> = []
    ) -> AssistantClient {
        switch frontmost {
        case .codex:
            return .codex
        case .other:
            return current
        case .terminal:
            switch (grokProcessRunning, claudeProcessRunning) {
            case (true, false):
                return .grok
            case (false, true):
                return .claude
            case (false, false):
                return .codex
            case (true, true):
                return preferredTerminalClient(
                    current: current,
                    frontmostTTY: frontmostTTY,
                    grokTTYs: grokTTYs,
                    claudeTTYs: claudeTTYs
                )
            }
        }
    }

    /// Cached identity is safe only when a single CLI is alive. Both CLIs
    /// share one terminal app, so tab switches need a TTY sample.
    static func immediateTerminalClient(
        grokProcessRunning: Bool,
        claudeProcessRunning: Bool
    ) -> AssistantClient? {
        switch (grokProcessRunning, claudeProcessRunning) {
        case (true, false):
            return .grok
        case (false, true):
            return .claude
        default:
            return nil
        }
    }

    /// When both CLIs are alive, a unique focused TTY wins. Otherwise keep
    /// the current identity. Observation / subagent evidence never selects
    /// the client; it only rotates while identity is already Grok.
    static func preferredTerminalClient(
        current: AssistantClient,
        frontmostTTY: String? = nil,
        grokTTYs: Set<String> = [],
        claudeTTYs: Set<String> = []
    ) -> AssistantClient {
        if let tty = TerminalCLIProcessRecord.normalizeTTY(frontmostTTY) {
            let grokMatch = grokTTYs.contains(tty)
            let claudeMatch = claudeTTYs.contains(tty)
            if grokMatch != claudeMatch {
                return grokMatch ? .grok : .claude
            }
        }
        if current == .grok || current == .claude {
            return current
        }
        return .claude
    }
}

struct ActivityCoordinatorActions {
    let activeClient: () -> AssistantClient
    let claudeProcessAvailable: () -> Bool
    let grokProcessAvailable: () -> Bool
    let setClaudeProcessAvailable: (Bool) -> Void
    let setGrokProcessAvailable: (Bool) -> Void
    let setActiveClient: (AssistantClient) -> Void
    let setCodexTaskRunning: (Bool) -> Void
    let setClaudeTaskRunning: (Bool) -> Void
    let setGrokTaskRunning: (Bool) -> Void
    let resetActivityRefreshState: () -> Void
    let observeCodexActivity: (ActivityLifecycleUpdate) -> Void
    let observeClaudeActivity: (ActivityLifecycleUpdate) -> Void
    let observeGrokActivity: (ActivityLifecycleUpdate) -> Void

    init(
        activeClient: @escaping () -> AssistantClient,
        claudeProcessAvailable: @escaping () -> Bool,
        grokProcessAvailable: @escaping () -> Bool = { false },
        setClaudeProcessAvailable: @escaping (Bool) -> Void,
        setGrokProcessAvailable: @escaping (Bool) -> Void = { _ in },
        setActiveClient: @escaping (AssistantClient) -> Void,
        setCodexTaskRunning: @escaping (Bool) -> Void,
        setClaudeTaskRunning: @escaping (Bool) -> Void,
        setGrokTaskRunning: @escaping (Bool) -> Void = { _ in },
        resetActivityRefreshState: @escaping () -> Void = {},
        observeCodexActivity: @escaping (ActivityLifecycleUpdate) -> Void = { _ in },
        observeClaudeActivity: @escaping (ActivityLifecycleUpdate) -> Void = { _ in },
        observeGrokActivity: @escaping (ActivityLifecycleUpdate) -> Void = { _ in }
    ) {
        self.activeClient = activeClient
        self.claudeProcessAvailable = claudeProcessAvailable
        self.grokProcessAvailable = grokProcessAvailable
        self.setClaudeProcessAvailable = setClaudeProcessAvailable
        self.setGrokProcessAvailable = setGrokProcessAvailable
        self.setActiveClient = setActiveClient
        self.setCodexTaskRunning = setCodexTaskRunning
        self.setClaudeTaskRunning = setClaudeTaskRunning
        self.setGrokTaskRunning = setGrokTaskRunning
        self.resetActivityRefreshState = resetActivityRefreshState
        self.observeCodexActivity = observeCodexActivity
        self.observeClaudeActivity = observeClaudeActivity
        self.observeGrokActivity = observeGrokActivity
    }
}

/// Owns activity polling, frontmost-app observation, and the accepted
/// activity monitors. It emits values; refresh/render policy remains in the
/// application composition root.
final class ActivityCoordinator {
    private let codexMonitor: CodexActivityMonitor
    private let claudeMonitor: ClaudeCodeActivityMonitor
    private let grokMonitor: GrokActivityMonitor
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
    private var grokLifecycle = ActivityLifecycleStateMachine()

    private(set) var startCount = 0

    init(
        codexMonitor: CodexActivityMonitor = CodexActivityMonitor(),
        claudeMonitor: ClaudeCodeActivityMonitor = ClaudeCodeActivityMonitor(),
        grokMonitor: GrokActivityMonitor = GrokActivityMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.activity-monitor", qos: .utility),
        actions: ActivityCoordinatorActions
    ) {
        self.codexMonitor = codexMonitor
        self.claudeMonitor = claudeMonitor
        self.grokMonitor = grokMonitor
        self.queue = queue
        self.actions = actions
    }

    func start(interval: TimeInterval) {
        guard !isStarted else { return }
        isStarted = true
        lifecycleGeneration &+= 1
        codexLifecycle.updateSampleInterval(interval)
        claudeLifecycle.updateSampleInterval(interval)
        grokLifecycle.updateSampleInterval(interval)
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
        grokLifecycle.updateSampleInterval(interval)
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
        TerminalFrontmostTTY.discardLatch()
        let codexWasRunning = codexLifecycle.reset()
        let claudeWasRunning = claudeLifecycle.reset()
        let grokWasRunning = grokLifecycle.reset()
        if wasStarted {
            actions.resetActivityRefreshState()
            if codexWasRunning { actions.setCodexTaskRunning(false) }
            if claudeWasRunning { actions.setClaudeTaskRunning(false) }
            if grokWasRunning { actions.setGrokTaskRunning(false) }
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
        let frontmostKind = Self.frontmostKind(NSWorkspace.shared.frontmostApplication)
        switch frontmostKind {
        case .codex:
            TerminalFrontmostTTY.discardLatch()
            actions.setActiveClient(.codex)
        case .other:
            TerminalFrontmostTTY.discardLatch()
        case .terminal:
            if let client = ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: actions.grokProcessAvailable(),
                claudeProcessRunning: actions.claudeProcessAvailable()
            ) {
                actions.setActiveClient(client)
            } else {
                refreshActivity()
            }
        }
    }

    private func refreshActivity() {
        guard isStarted else { return }
        applyCachedFrontmostClient()
        guard !isCheckInFlight else { return }
        let frontmostKind = Self.frontmostKind(NSWorkspace.shared.frontmostApplication)
        let clientBeforeCheck = actions.activeClient()
        let sampledClient = ActivityClientSelection.client(
            frontmost: frontmostKind,
            current: clientBeforeCheck,
            grokProcessRunning: actions.grokProcessAvailable(),
            claudeProcessRunning: actions.claudeProcessAvailable()
        )
        if sampledClient != lastSampledClient {
            codexLifecycle.clearPendingTransition()
            claudeLifecycle.clearPendingTransition()
            grokLifecycle.clearPendingTransition()
            lastSampledClient = sampledClient
        }
        let generation = lifecycleGeneration
        isCheckInFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            var codexObservation: ActivityMonitorObservation?
            var claudeStatus: ClaudeActivityStatus?
            var grokStatus: GrokActivityStatus?
            var processSnapshot: TerminalCLIProcessSnapshot?
            switch frontmostKind {
            case .codex:
                codexObservation = self.codexMonitor.activityObservation()
            case .terminal:
                grokStatus = self.grokMonitor.activityStatus()
                claudeStatus = self.claudeMonitor.activityStatus()
                if grokStatus?.processRunning == true,
                   claudeStatus?.processRunning == true {
                    processSnapshot = TerminalCLIProcessSnapshot.load()
                }
                if grokStatus?.processRunning != true,
                   claudeStatus?.processRunning != true {
                    codexObservation = self.codexMonitor.activityObservation()
                }
            case .other:
                switch clientBeforeCheck {
                case .codex:
                    codexObservation = self.codexMonitor.activityObservation()
                case .claude:
                    claudeStatus = self.claudeMonitor.activityStatus()
                case .grok:
                    grokStatus = self.grokMonitor.activityStatus()
                }
            }
            let sampledAt = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isStarted, self.lifecycleGeneration == generation else { return }
                self.isCheckInFlight = false
                if let claudeStatus,
                   self.actions.claudeProcessAvailable() != claudeStatus.processRunning {
                    self.actions.setClaudeProcessAvailable(claudeStatus.processRunning)
                }
                if let grokStatus,
                   self.actions.grokProcessAvailable() != grokStatus.processRunning {
                    self.actions.setGrokProcessAvailable(grokStatus.processRunning)
                }
                let application = NSWorkspace.shared.frontmostApplication
                let currentFrontmost = Self.frontmostKind(application)
                if currentFrontmost != .terminal {
                    TerminalFrontmostTTY.discardLatch()
                }
                let grokRunning = grokStatus?.processRunning
                    ?? self.actions.grokProcessAvailable()
                let claudeRunning = claudeStatus?.processRunning
                    ?? self.actions.claudeProcessAvailable()
                let snapshot = processSnapshot
                    ?? ((currentFrontmost == .terminal && grokRunning && claudeRunning)
                        ? TerminalCLIProcessSnapshot.load()
                        : nil)
                let frontmostTTY = snapshot.flatMap {
                    TerminalFrontmostTTY.resolve(application: application, snapshot: $0)
                } ?? TerminalFrontmostTTY.selectedTTY(application: application)
                let selected = ActivityClientSelection.client(
                    frontmost: currentFrontmost,
                    current: self.actions.activeClient(),
                    grokProcessRunning: grokRunning,
                    claudeProcessRunning: claudeRunning,
                    frontmostTTY: frontmostTTY,
                    grokTTYs: snapshot?.grokTTYs ?? Set(grokStatus?.ttys ?? []),
                    claudeTTYs: snapshot?.claudeTTYs ?? Set(claudeStatus?.ttys ?? [])
                )
                self.actions.setActiveClient(selected)
                if selected != self.lastSampledClient {
                    self.codexLifecycle.clearPendingTransition()
                    self.claudeLifecycle.clearPendingTransition()
                    self.grokLifecycle.clearPendingTransition()
                    self.lastSampledClient = selected
                }
                if let codexObservation {
                    let update = self.codexLifecycle.observeUpdate(codexObservation, at: sampledAt)
                    self.actions.observeCodexActivity(update)
                    self.actions.setCodexTaskRunning(update.taskRunning)
                }
                if let claudeStatus {
                    let update = self.claudeLifecycle.observeUpdate(claudeStatus.observation, at: sampledAt)
                    self.actions.observeClaudeActivity(update)
                    self.actions.setClaudeTaskRunning(update.taskRunning)
                }
                if let grokStatus {
                    let update = self.grokLifecycle.observeUpdate(grokStatus.observation, at: sampledAt)
                    self.actions.observeGrokActivity(update)
                    self.actions.setGrokTaskRunning(update.taskRunning)
                }
            }
        }
    }

    private func applyCachedFrontmostClient() {
        let frontmostKind = Self.frontmostKind(NSWorkspace.shared.frontmostApplication)
        switch frontmostKind {
        case .codex:
            TerminalFrontmostTTY.discardLatch()
            actions.setActiveClient(.codex)
        case .other:
            TerminalFrontmostTTY.discardLatch()
        case .terminal:
            if let client = ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: actions.grokProcessAvailable(),
                claudeProcessRunning: actions.claudeProcessAvailable()
            ) {
                actions.setActiveClient(client)
            }
        }
    }

    static func frontmostKind(_ application: NSRunningApplication?) -> ActivityFrontmostKind {
        if isCodexApplication(application) { return .codex }
        if isTerminalApplication(application) { return .terminal }
        return .other
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
