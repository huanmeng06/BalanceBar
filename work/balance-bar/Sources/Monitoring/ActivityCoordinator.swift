import AppKit

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
        configureTimer(interval: interval)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        isStarted = false
        isCheckInFlight = false
    }

    func pollNow() { refreshActivity() }

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
        handleFrontmostApplicationChangeWithoutRefresh()
        guard !isCheckInFlight else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostIsCodex = Self.isCodexApplication(frontmost)
        let frontmostIsTerminal = Self.isTerminalApplication(frontmost)
        let clientBeforeCheck = actions.activeClient()
        isCheckInFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            var codexRunning: Bool?
            var claudeStatus: (processRunning: Bool, taskRunning: Bool)?
            if frontmostIsCodex {
                codexRunning = self.codexMonitor.isTaskRunning()
            } else if frontmostIsTerminal {
                let status = self.claudeMonitor.status()
                claudeStatus = status
                if !status.processRunning {
                    codexRunning = self.codexMonitor.isTaskRunning()
                }
            } else if clientBeforeCheck == .codex {
                codexRunning = self.codexMonitor.isTaskRunning()
            } else {
                claudeStatus = self.claudeMonitor.status()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
                if let codexRunning { self.actions.setCodexTaskRunning(codexRunning) }
                if let claudeStatus { self.actions.setClaudeTaskRunning(claudeStatus.taskRunning) }
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
