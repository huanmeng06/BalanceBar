import Foundation
import XCTest
@testable import BalanceBar

final class ActivityCoordinatorTests: XCTestCase {
    func testTerminalWithOnlyGrokSelectsGrok() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: false
            ),
            .grok
        )
    }

    func testTerminalWithOnlyClaudeKeepsClaude() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .codex,
                grokProcessRunning: false,
                claudeProcessRunning: true
            ),
            .claude
        )
    }

    func testBackgroundProcessesDoNotStealCodex() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .codex,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true
            ),
            .codex
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .other,
                current: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: false
            ),
            .codex
        )
    }

    func testFrontmostClaudeTTYWinsEvenIfGrokIsActiveAndCurrentIsGrok() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys002",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .claude
        )
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: "/dev/ttys002",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .claude
        )
    }

    func testFrontmostGrokTTYWinsWithoutTrueTurnEvidence() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .grok
        )
    }

    func testNoTTYKeepsCurrentWhenBothCLIsAreAlive() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true
            ),
            .claude
        )
    }

    func testCodexFrontmostIsNotStolenByBackgroundGrokOrClaude() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .codex,
                current: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .codex
        )
    }

    func testGrokSubagentDoesNotStealFocusedClaudeTTY() {
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .claude,
                frontmostTTY: "ttys002",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .claude
        )
    }

    func testGrokIdentityStillFollowsGrokTTYWhileSubagentIsActive() {
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .grok
        )
    }

    func testProcessCacheTTYSetsClassifyIdentityWithoutSessionScan() {
        XCTAssertEqual(
            TerminalFrontmostTTY.uniquelyClassifiedTTY(
                "/dev/ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            "ttys001"
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .claude,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .grok
        )
        XCTAssertNil(
            TerminalFrontmostTTY.uniquelyClassifiedTTY(
                "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys001"]
            )
        )
    }

    func testImmediateTerminalClientWaitsWhenBothExist() {
        XCTAssertEqual(
            ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: true,
                claudeProcessRunning: false
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: false,
                claudeProcessRunning: true
            ),
            .claude
        )
        XCTAssertNil(
            ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: true,
                claudeProcessRunning: true
            )
        )
        XCTAssertNil(
            ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: false,
                claudeProcessRunning: false
            )
        )
    }

    func testSelectedClaudeTTYWinsWhenSeveralGrokTTYsShareOneTerminalPID() {
        XCTAssertEqual(
            TerminalFrontmostTTY.uniquelyClassifiedTTY(
                "ttys003",
                grokTTYs: ["ttys000", "ttys001", "ttys002"],
                claudeTTYs: ["ttys003"]
            ),
            "ttys003"
        )
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: "ttys003",
                grokTTYs: ["ttys000", "ttys001", "ttys002"],
                claudeTTYs: ["ttys003"]
            ),
            .claude
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .codex,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys003",
                grokTTYs: ["ttys000", "ttys001", "ttys002"],
                claudeTTYs: ["ttys003"]
            ),
            .codex
        )
    }

    func testDualCLITerminalFrontmostUsesFastIdentityInterval() {
        XCTAssertEqual(ActivityIdentityPolling.dualCLIFrontmostInterval, 0.1, accuracy: 0.000_1)
        XCTAssertTrue(
            ActivityIdentityPolling.shouldUseFastIdentity(
                frontmost: .terminal,
                grokProcessRunning: true,
                claudeProcessRunning: true
            )
        )
        XCTAssertEqual(
            ActivityIdentityPolling.identityInterval(
                frontmost: .terminal,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                configuredPollInterval: 1.0
            ),
            0.1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ActivityIdentityPolling.identityInterval(
                frontmost: .terminal,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                configuredPollInterval: 0.25
            ),
            0.1,
            accuracy: 0.000_1
        )
    }

    func testIdentityFollowsConfiguredPollWhenFastPathIsInactive() {
        XCTAssertFalse(
            ActivityIdentityPolling.shouldUseFastIdentity(
                frontmost: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: true
            )
        )
        XCTAssertFalse(
            ActivityIdentityPolling.shouldUseFastIdentity(
                frontmost: .terminal,
                grokProcessRunning: true,
                claudeProcessRunning: false
            )
        )
        XCTAssertFalse(
            ActivityIdentityPolling.shouldUseFastIdentity(
                frontmost: .terminal,
                grokProcessRunning: false,
                claudeProcessRunning: true
            )
        )
        XCTAssertFalse(
            ActivityIdentityPolling.shouldUseFastIdentity(
                frontmost: .other,
                grokProcessRunning: true,
                claudeProcessRunning: true
            )
        )
        XCTAssertEqual(
            ActivityIdentityPolling.identityInterval(
                frontmost: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                configuredPollInterval: 1.0
            ),
            1.0
        )
        XCTAssertEqual(
            ActivityIdentityPolling.identityInterval(
                frontmost: .terminal,
                grokProcessRunning: true,
                claudeProcessRunning: false,
                configuredPollInterval: 0.25
            ),
            0.25
        )
        XCTAssertEqual(
            ActivityIdentityPolling.identityInterval(
                frontmost: .other,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                configuredPollInterval: 0.5
            ),
            0.5
        )
    }

    func testFastIdentityTimerStartsOnlyForDualCLITerminal() {
        let harness = CoordinatorHarness()
        harness.grokRunning = true
        harness.claudeRunning = true
        defer { harness.coordinator.stop() }
        harness.coordinator.start(interval: 1.0)

        XCTAssertFalse(harness.coordinator.isFastIdentityPollingEnabled)
        XCTAssertNil(harness.coordinator.identityTimerIntervalForTests)
        XCTAssertEqual(
            harness.coordinator.pollTimerIntervalForTests ?? 0,
            1.0,
            accuracy: 0.000_1
        )

        harness.coordinator.applyIdentityPollingStateForTests(
            frontmost: .terminal,
            grokRunning: true,
            claudeRunning: true
        )
        XCTAssertTrue(harness.coordinator.isFastIdentityPollingEnabled)
        XCTAssertEqual(
            harness.coordinator.identityTimerIntervalForTests ?? 0,
            0.1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            harness.coordinator.pollTimerIntervalForTests ?? 0,
            1.0,
            accuracy: 0.000_1
        )

        harness.coordinator.applyIdentityPollingStateForTests(
            frontmost: .codex,
            grokRunning: true,
            claudeRunning: true
        )
        XCTAssertFalse(harness.coordinator.isFastIdentityPollingEnabled)
        XCTAssertNil(harness.coordinator.identityTimerIntervalForTests)
        XCTAssertEqual(
            harness.coordinator.pollTimerIntervalForTests ?? 0,
            1.0,
            accuracy: 0.000_1
        )
    }

    func testIdentityCompletionDoesNotSetActiveClientWhenUnchanged() {
        let harness = CoordinatorHarness()
        harness.activeClient = .grok
        harness.setActiveClientCallCount = 0
        harness.coordinator.applySelectedClientForTests(.grok)
        XCTAssertEqual(harness.setActiveClientCallCount, 0)
        XCTAssertEqual(harness.activeClient, .grok)

        harness.coordinator.applySelectedClientForTests(.claude)
        XCTAssertEqual(harness.setActiveClientCallCount, 1)
        XCTAssertEqual(harness.activeClient, .claude)
    }

    func testFastIdentityDoesNotProbeProcessesWhenTTYCacheIsWarm() {
        final class ProbeCounter: @unchecked Sendable {
            var grok = 0
            var claude = 0
        }
        let counter = ProbeCounter()
        var now = Date(timeIntervalSince1970: 1_000)
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let grok = GrokActivityMonitor(
            grokDirectory: fixture,
            clock: { now },
            processRunner: { _, _ in
                counter.grok += 1
                return GrokProcessResult(
                    standardOutput: Data(
                        "202 1 ttys001 grok-macos-aarch64 /Users/dev/.grok/bin/grok".utf8
                    ),
                    terminationStatus: 0
                )
            }
        )
        let claude = ClaudeCodeActivityMonitor(
            projectsDirectory: fixture,
            clock: { now },
            processRunner: { _, _ in
                counter.claude += 1
                return ClaudeProcessResult(
                    standardOutput: Data("203 1 ttys002 claude /usr/local/bin/claude".utf8),
                    terminationStatus: 0
                )
            }
        )
        let harness = CoordinatorHarness(grokMonitor: grok, claudeMonitor: claude)
        harness.grokRunning = true
        harness.claudeRunning = true
        defer { harness.coordinator.stop() }
        harness.coordinator.start(interval: 1.0)

        harness.coordinator.refreshIdentityForTests(
            frontmost: .terminal,
            allowProcessProbe: true
        )
        XCTAssertEqual(counter.grok, 1)
        XCTAssertEqual(counter.claude, 1)
        XCTAssertEqual(harness.coordinator.cachedGrokTTYsForTests, ["ttys001"])
        XCTAssertEqual(harness.coordinator.cachedClaudeTTYsForTests, ["ttys002"])

        now += 2
        harness.coordinator.refreshIdentityForTests(
            frontmost: .terminal,
            allowProcessProbe: false
        )
        XCTAssertEqual(counter.grok, 1)
        XCTAssertEqual(counter.claude, 1)
    }

    func testIdentityOnlyRefreshDoesNotScheduleTaskActivity() {
        let harness = CoordinatorHarness()
        harness.grokRunning = true
        harness.claudeRunning = true
        defer { harness.coordinator.stop() }
        harness.coordinator.start(interval: 1.0)
        harness.coordinator.applyIdentityPollingStateForTests(
            frontmost: .terminal,
            grokRunning: true,
            claudeRunning: true
        )
        let activityBefore = harness.coordinator.taskActivityScheduleCountForTests
        harness.coordinator.refreshIdentityOnlyForTests()
        XCTAssertEqual(
            harness.coordinator.taskActivityScheduleCountForTests,
            activityBefore
        )
    }

    func testGrokExitWhileTerminalFrontmostFallsBackToClaudeOrCodex() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: false,
                claudeProcessRunning: true
            ),
            .claude
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: false,
                claudeProcessRunning: false
            ),
            .codex
        )
    }
}

private final class CoordinatorHarness {
    var grokRunning = false
    var claudeRunning = false
    var activeClient: AssistantClient = .codex
    var setActiveClientCallCount = 0
    private let grokMonitor: GrokActivityMonitor
    private let claudeMonitor: ClaudeCodeActivityMonitor
    lazy var coordinator = ActivityCoordinator(
        claudeMonitor: claudeMonitor,
        grokMonitor: grokMonitor,
        actions: ActivityCoordinatorActions(
            activeClient: { [unowned self] in self.activeClient },
            claudeProcessAvailable: { [unowned self] in self.claudeRunning },
            grokProcessAvailable: { [unowned self] in self.grokRunning },
            setClaudeProcessAvailable: { [unowned self] in self.claudeRunning = $0 },
            setGrokProcessAvailable: { [unowned self] in self.grokRunning = $0 },
            setActiveClient: { [unowned self] in
                self.setActiveClientCallCount += 1
                self.activeClient = $0
            },
            setCodexTaskRunning: { _ in },
            setClaudeTaskRunning: { _ in },
            setGrokTaskRunning: { _ in }
        )
    )

    init(
        grokMonitor: GrokActivityMonitor = GrokActivityMonitor(),
        claudeMonitor: ClaudeCodeActivityMonitor = ClaudeCodeActivityMonitor()
    ) {
        self.grokMonitor = grokMonitor
        self.claudeMonitor = claudeMonitor
    }
}
