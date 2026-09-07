import Foundation
import XCTest
@testable import BalanceBar

final class GrokActivityMonitorTests: XCTestCase {
    private var fixtureDirectory: URL!
    private var currentDate = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        currentDate = Date(timeIntervalSince1970: 2_000_000_000)
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-GrokActivityMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        try super.tearDownWithError()
    }

    func testProcessPresenceAndMissingSession() {
        let monitor = makeMonitor(processOutput: "101 1 ?? /Users/dev/.grok/bin/grok grok")

        let status = monitor.status()

        XCTAssertTrue(status.processRunning)
        XCTAssertFalse(status.taskRunning)
    }

    func testProcessAbsenceDoesNotReadSessions() {
        let monitor = makeMonitor(processOutput: "101 1 ?? /usr/bin/python python grok.py")

        let status = monitor.status()

        XCTAssertFalse(status.processRunning)
        XCTAssertFalse(status.taskRunning)
    }

    func testUnrelatedArgumentsContainingGrokAreIgnored() {
        XCTAssertFalse(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "101 1 ?? /bin/echo echo grok"
            )
        )
        XCTAssertFalse(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "101 1 ?? /usr/bin/rg rg grok updates.jsonl"
            )
        )
        XCTAssertTrue(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "101 1 ?? /Users/dev/.grok/bin/grok grok"
            )
        )
        XCTAssertTrue(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "202 1 ttys000 grok-macos-aarch64 /Users/dev/.grok/bin/grok"
            )
        )
        XCTAssertFalse(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "101 1 ?? UserEventAgent /usr/libexec/UserEventAgent (System)"
            )
        )
        XCTAssertFalse(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "38864 38839 ?? agent agent",
                confirmedAgentPIDs: [38864]
            )
        )
        XCTAssertFalse(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "38864 38839 ttys000 agent agent"
            )
        )
        XCTAssertTrue(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "38864 38839 ttys000 agent agent",
                confirmedAgentPIDs: [38864]
            )
        )
        XCTAssertTrue(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "38864 38839 ttys000 /Users/dev/.grok/bin/agent /Users/dev/.grok/bin/agent"
            )
        )
        XCTAssertTrue(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "38864 38839 ttys000 agent /Users/dev/.grok/downloads/grok-macos-aarch64"
            )
        )
    }

    func testLivePSCommColumnPaddingRecognizesConfirmedBareAgent() {
        let livePaddedLine = "38864 38839 ttys000  agent            agent"
        XCTAssertTrue(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                livePaddedLine,
                confirmedAgentPIDs: [38864]
            )
        )
        XCTAssertFalse(
            GrokActivityMonitor.lineLooksLikeGrokCLI(livePaddedLine)
        )
        XCTAssertFalse(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "38864 38839 ??  agent            agent",
                confirmedAgentPIDs: [38864]
            )
        )
        XCTAssertFalse(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "101 1 ?? UserEventAgent /usr/libexec/UserEventAgent (System)"
            )
        )
        XCTAssertFalse(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "101 1 ttys000 distnoted distnoted agent"
            )
        )
        XCTAssertTrue(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "38864 38839 ttys000 agent agent",
                confirmedAgentPIDs: [38864]
            )
        )
        XCTAssertTrue(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "202 1 ttys000 grok grok"
            )
        )
        XCTAssertTrue(
            GrokActivityMonitor.lineLooksLikeGrokCLI(
                "202 1 ttys000 grok-macos-aarch64 /Users/dev/.grok/bin/grok"
            )
        )
    }

    func testConfirmedBareAgentProcessPresenceExposesTTY() throws {
        try writeActiveSessions([
            [
                "session_id": "agent-tui",
                "pid": 38864,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])
        let presence = makeMonitor(
            processOutput: "38864 38839 ttys000 agent agent"
        ).processPresence()
        XCTAssertTrue(presence.running)
        XCTAssertEqual(presence.ttys, ["ttys000"])
    }

    func testLivePSCommColumnPaddingConfirmedBareAgentProcessPresenceExposesTTY() throws {
        try writeActiveSessions([
            [
                "session_id": "agent-tui",
                "pid": 38864,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])
        let presence = makeMonitor(
            processOutput: "38864 38839 ttys000  agent            agent"
        ).processPresence()
        XCTAssertTrue(presence.running)
        XCTAssertEqual(presence.ttys, ["ttys000"])
    }

    func testLivePSCommColumnPaddingBareAgentWithoutConfirmedPIDIsNotGrokProcess() throws {
        try writeActiveSessions([])
        let presence = makeMonitor(
            processOutput: "38864 38839 ttys000  agent            agent"
        ).processPresence()
        XCTAssertFalse(presence.running)
        XCTAssertEqual(presence.ttys, [])
    }

    func testBareAgentWithoutConfirmedPIDIsNotGrokProcess() throws {
        try writeActiveSessions([])
        let presence = makeMonitor(
            processOutput: "38864 38839 ttys000 agent agent"
        ).processPresence()
        XCTAssertFalse(presence.running)
        XCTAssertEqual(presence.ttys, [])
    }

    func testGrokBinAgentPathIsGrokProcessWithoutSessionJSON() {
        let binAgent = makeMonitor(
            processOutput: "38864 38839 ttys000 /Users/dev/.grok/bin/agent /Users/dev/.grok/bin/agent"
        ).processPresence()
        XCTAssertTrue(binAgent.running)
        XCTAssertEqual(binAgent.ttys, ["ttys000"])

        let macosAgent = makeMonitor(
            processOutput: "38864 38839 ttys000 agent /Users/dev/.grok/downloads/grok-macos-aarch64"
        ).processPresence()
        XCTAssertTrue(macosAgent.running)
        XCTAssertEqual(macosAgent.ttys, ["ttys000"])
    }

    func testConfirmedBareAgentKeepsGrokIdentityAfterClosingGrokWindow() throws {
        try writeActiveSessions([
            [
                "session_id": "agent-tui",
                "pid": 38864,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])
        let onlyAgent = makeMonitor(
            processOutput: "38864 38839 ttys000 agent agent"
        ).processPresence()
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .codex,
                grokProcessRunning: onlyAgent.running,
                claudeProcessRunning: false,
                frontmostTTY: onlyAgent.ttys.first,
                grokTTYs: Set(onlyAgent.ttys)
            ),
            .grok
        )

        let both = makeMonitor(
            processOutput: """
            38864 38839 ttys000 agent agent
            40809 40800 ttys001 grok grok
            """
        ).processPresence()
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: both.running,
                claudeProcessRunning: false
            ),
            .grok
        )

        let afterClosingGrok = makeMonitor(
            processOutput: "38864 38839 ttys000 agent agent"
        ).processPresence()
        XCTAssertTrue(afterClosingGrok.running)
        XCTAssertEqual(afterClosingGrok.ttys, ["ttys000"])
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: afterClosingGrok.running,
                claudeProcessRunning: false
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .codex,
                current: .grok,
                grokProcessRunning: afterClosingGrok.running,
                claudeProcessRunning: false
            ),
            .codex
        )
    }

    func testLivePSCommColumnPaddingKeepsGrokIdentityAfterClosingGrokWindow() throws {
        try writeActiveSessions([
            [
                "session_id": "agent-tui",
                "pid": 38864,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])
        let onlyAgent = makeMonitor(
            processOutput: "38864 38839 ttys000  agent            agent"
        ).processPresence()
        XCTAssertTrue(onlyAgent.running)
        XCTAssertEqual(onlyAgent.ttys, ["ttys000"])
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .codex,
                grokProcessRunning: onlyAgent.running,
                claudeProcessRunning: false,
                frontmostTTY: onlyAgent.ttys.first,
                grokTTYs: Set(onlyAgent.ttys)
            ),
            .grok
        )

        let afterClosingGrok = makeMonitor(
            processOutput: "38864 38839 ttys000  agent            agent"
        ).processPresence()
        XCTAssertTrue(afterClosingGrok.running)
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: afterClosingGrok.running,
                claudeProcessRunning: false
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .codex,
                current: .grok,
                grokProcessRunning: afterClosingGrok.running,
                claudeProcessRunning: false
            ),
            .codex
        )
    }

    func testSystemAgentAndGrokSubstringsAreNotGrokProcess() {
        XCTAssertFalse(
            makeMonitor(
                processOutput: "101 1 ?? UserEventAgent /usr/libexec/UserEventAgent (System)"
            ).processPresence().running
        )
        XCTAssertFalse(
            makeMonitor(
                processOutput: "101 1 ttys000 /bin/echo echo grok"
            ).processPresence().running
        )
        XCTAssertFalse(
            makeMonitor(
                processOutput: "101 1 ttys000 /usr/bin/rg rg grok updates.jsonl"
            ).processPresence().running
        )
        XCTAssertFalse(
            makeMonitor(
                processOutput: "38864 38839 ?? agent agent"
            ).processPresence().running
        )
        XCTAssertFalse(
            makeMonitor(
                processOutput: "38864 38839 ??  agent            agent"
            ).processPresence().running
        )
        XCTAssertFalse(
            makeMonitor(
                processOutput: "101 1 ttys000 distnoted distnoted agent"
            ).processPresence().running
        )
    }

    func testProcessStatusExposesTTYFromPS() {
        let status = makeMonitor(
            processOutput: "202 1 ttys001 grok-macos-aarch64 /Users/dev/.grok/bin/grok"
        ).activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.ttys, ["ttys001"])
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testProcessPresenceDoesNotRequireSessionScan() {
        let monitor = makeMonitor(
            processOutput: "202 1 ttys001 grok-macos-aarch64 /Users/dev/.grok/bin/grok"
        )
        let presence = monitor.processPresence()
        XCTAssertTrue(presence.running)
        XCTAssertEqual(presence.ttys, ["ttys001"])
        XCTAssertEqual(monitor.status().processRunning, true)
        XCTAssertFalse(monitor.status().taskRunning)
    }

    func testThoughtAndToolEventsAreActive() throws {
        try writeSession(updates: [
            sessionUpdate("user_message_chunk"),
            sessionUpdate("agent_thought_chunk")
        ])
        let thinking = makeMonitor().activityStatus()
        XCTAssertTrue(thinking.observation.legacyIsTaskRunning)
        XCTAssertTrue(thinking.trueTurnEvidence)

        try writeSession(updates: [
            sessionUpdate("tool_call")
        ], sessionID: "tool")
        let tool = makeMonitor().activityStatus()
        XCTAssertTrue(tool.observation.legacyIsTaskRunning)
        XCTAssertTrue(tool.trueTurnEvidence)
    }

    func testRecentWriteWithoutThoughtsIsNotTrueTurnEvidence() throws {
        try writeSession(updates: [
            sessionUpdate("user_message_chunk")
        ])
        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testTurnCompletedIsHardTerminal() throws {
        try writeSession(updates: [
            sessionUpdate("agent_thought_chunk"),
            sessionUpdate("agent_message_chunk"),
            sessionUpdate("turn_completed")
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testParentTurnCompletedStillActiveWhenSubagentTranscriptIsActive() throws {
        try writeSession(
            updates: [
                sessionUpdate("user_message_chunk", timestamp: currentDate.timeIntervalSince1970 - 20),
                sessionUpdate("subagent_spawned", timestamp: currentDate.timeIntervalSince1970 - 5),
                sessionUpdate("turn_completed")
            ],
            sessionID: "parent"
        )
        try writeSubagentUpdates(
            parentSessionID: "parent",
            subagentID: "child",
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: currentDate.timeIntervalSince1970 + 1)
            ],
            modifiedAt: currentDate.addingTimeInterval(1)
        )
        try writeActiveSessions([
            [
                "session_id": "parent",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
        XCTAssertTrue(status.trueTurnEvidence)
    }

    func testParentBackgroundedStillActiveWhenChildSessionFromMetaIsActive() throws {
        try writeSession(
            updates: [
                sessionUpdate("user_message_chunk", timestamp: currentDate.timeIntervalSince1970 - 30),
                sessionUpdate("task_backgrounded"),
                sessionUpdate("turn_completed")
            ],
            sessionID: "parent"
        )
        try writeSubagentMeta(
            parentSessionID: "parent",
            subagentID: "child-session",
            childCWD: "/tmp/child-work",
            status: "running"
        )
        try writeSession(
            updates: [sessionUpdate("tool_call")],
            cwd: "/tmp/child-work",
            sessionID: "child-session",
            modifiedAt: currentDate.addingTimeInterval(2)
        )
        try writeActiveSessions([
            [
                "session_id": "parent",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
        XCTAssertTrue(status.trueTurnEvidence)
    }

    func testTurnCompletedWithoutSubagentDoesNotRotate() throws {
        try writeSession(updates: [
            sessionUpdate("user_message_chunk"),
            sessionUpdate("agent_message_chunk"),
            sessionUpdate("turn_completed")
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
        XCTAssertFalse(status.observation.isActiveEvidence)
    }

    func testMissingProcessDoesNotRotate() {
        let status = makeMonitor(processOutput: "101 1 ?? /usr/bin/python python grok.py").activityStatus()
        XCTAssertFalse(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testOlderInProgressSessionKeepsRunningWhenNewerCompleted() throws {
        try writeSession(
            updates: [sessionUpdate("agent_thought_chunk")],
            sessionID: "older",
            modifiedAt: currentDate.addingTimeInterval(-30)
        )
        try writeSession(
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: currentDate.timeIntervalSince1970 - 10),
                sessionUpdate("turn_completed")
            ],
            sessionID: "newer",
            modifiedAt: currentDate
        )
        try writeActiveSessions([
            [
                "session_id": "older",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ],
            [
                "session_id": "newer",
                "pid": 102,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:01:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
    }

    func testUserMessageChunkFromSixtySecondsAgoIsStillRunning() throws {
        try writeSession(
            updates: [
                sessionUpdate(
                    "user_message_chunk",
                    timestamp: currentDate.timeIntervalSince1970 - 60
                )
            ],
            modifiedAt: currentDate.addingTimeInterval(-60)
        )

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
    }

    func testPlanAfterTurnCompletedIsStillRunning() throws {
        try writeSession(updates: [
            sessionUpdate("turn_completed", timestamp: currentDate.timeIntervalSince1970 - 2),
            sessionUpdate("plan")
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
    }

    func testParentAndChildrenExplicitCompletionIsNotRunningEvenIfJustWritten() throws {
        try writeSession(
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: currentDate.timeIntervalSince1970 - 1),
                sessionUpdate("turn_completed")
            ],
            sessionID: "parent",
            modifiedAt: currentDate
        )
        try writeSubagentMeta(
            parentSessionID: "parent",
            subagentID: "child",
            childCWD: "/tmp/child-work",
            status: "completed"
        )
        try writeSubagentUpdates(
            parentSessionID: "parent",
            subagentID: "child",
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: currentDate.timeIntervalSince1970 - 1),
                sessionUpdate("turn_completed")
            ],
            modifiedAt: currentDate
        )
        try writeActiveSessions([
            [
                "session_id": "parent",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testProcessGoneIsNotRunningEvenWithInProgressSession() throws {
        try writeSession(updates: [sessionUpdate("agent_thought_chunk")])

        let status = makeMonitor(
            processOutput: "101 1 ?? /usr/bin/python python grok.py"
        ).activityStatus()
        XCTAssertFalse(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testEmptyActiveSessionsIsIdleEvenIfSessionFilesExist() throws {
        try writeSession(
            updates: [sessionUpdate("agent_thought_chunk")],
            registerActive: false
        )
        try writeActiveSessions([])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testUnlistedSameCwdSiblingThoughtKeepsRunningWhenListedTurnCompleted() throws {
        try writeSession(
            updates: [sessionUpdate("agent_thought_chunk")],
            sessionID: "sibling-a",
            registerActive: false
        )
        try writeSession(
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: currentDate.timeIntervalSince1970 - 5),
                sessionUpdate("turn_completed")
            ],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
        XCTAssertTrue(status.trueTurnEvidence)
    }

    func testUnlistedSameCwdSiblingUnfinishedSubagentKeepsRunningWhenListedTurnCompleted() throws {
        try writeSession(
            updates: [
                sessionUpdate("user_message_chunk", timestamp: currentDate.timeIntervalSince1970 - 20),
                sessionUpdate("turn_completed")
            ],
            sessionID: "sibling-a",
            registerActive: false
        )
        try writeSubagentMeta(
            parentSessionID: "sibling-a",
            subagentID: "child",
            childCWD: "/tmp/child-work",
            status: "running"
        )
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
    }

    func testUnlistedSameCwdSiblingActiveWorkflowKeepsRunningWhenListedTurnCompleted() throws {
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "sibling-a",
            registerActive: false
        )
        try writeWorkflowState(
            sessionID: "sibling-a",
            runID: "wf_active",
            status: "active"
        )
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
    }

    func testUnlistedSiblingCompletedTurnWithUnmatchedBackgroundIsHardTerminal() throws {
        let siblingCompletedAt = currentDate
        try writeSession(
            updates: [
                sessionUpdate(
                    "user_message_chunk",
                    timestamp: siblingCompletedAt.timeIntervalSince1970 - 30
                ),
                sessionUpdate(
                    "turn_completed",
                    timestamp: siblingCompletedAt.timeIntervalSince1970 - 1
                ),
                taskBackgrounded(
                    "bg-dead",
                    timestamp: siblingCompletedAt.timeIntervalSince1970 - 1
                )
            ],
            sessionID: "sibling-a",
            modifiedAt: siblingCompletedAt,
            registerActive: false
        )
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate.addingTimeInterval(-3_600))
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testListedNeverStartedStubDoesNotResurrectCompletedUnlistedSibling() throws {
        let stubOpened = currentDate.addingTimeInterval(-7_200)
        let siblingCompleted = currentDate.addingTimeInterval(-60)
        try writeSession(
            updates: [
                sessionUpdate(
                    "user_message_chunk",
                    timestamp: siblingCompleted.timeIntervalSince1970 - 30
                ),
                sessionUpdate(
                    "turn_completed",
                    timestamp: siblingCompleted.timeIntervalSince1970
                ),
                taskBackgrounded(
                    "bg-dead",
                    timestamp: siblingCompleted.timeIntervalSince1970
                )
            ],
            sessionID: "sibling-a",
            modifiedAt: siblingCompleted,
            registerActive: false
        )
        try writeListedStubSession(sessionID: "listed-stub")
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-stub",
                "pid": 102,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(stubOpened)
            ],
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testListedNeverStartedStubDoesNotLowerOpenedAtFloorForStaleSibling() throws {
        let stubOpened = currentDate.addingTimeInterval(-7_200)
        let staleDate = currentDate.addingTimeInterval(-3_600)
        try writeSession(
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: staleDate.timeIntervalSince1970)
            ],
            sessionID: "sibling-a",
            modifiedAt: staleDate,
            registerActive: false
        )
        try writeListedStubSession(sessionID: "listed-stub")
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-stub",
                "pid": 102,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(stubOpened)
            ],
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testUnlistedSiblingThoughtKeepsRunningWhenListedIncludesNeverStartedStub() throws {
        try writeSession(
            updates: [sessionUpdate("agent_thought_chunk")],
            sessionID: "sibling-a",
            registerActive: false
        )
        try writeListedStubSession(sessionID: "listed-stub")
        try writeSession(
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: currentDate.timeIntervalSince1970 - 5),
                sessionUpdate("turn_completed")
            ],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-stub",
                "pid": 102,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate.addingTimeInterval(-7_200))
            ],
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
        XCTAssertTrue(status.trueTurnEvidence)
    }

    func testUnlistedSiblingUnmatchedBackgroundStillActiveWhenSubagentUnfinished() throws {
        try writeSession(
            updates: [
                sessionUpdate("user_message_chunk", timestamp: currentDate.timeIntervalSince1970 - 20),
                sessionUpdate("turn_completed"),
                taskBackgrounded("bg-dead")
            ],
            sessionID: "sibling-a",
            registerActive: false
        )
        try writeSubagentMeta(
            parentSessionID: "sibling-a",
            subagentID: "child",
            childCWD: "/tmp/child-work",
            status: "running"
        )
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
    }

    func testUnlistedSameCwdSiblingExplicitCompletionIsHardTerminal() throws {
        try writeSession(
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: currentDate.timeIntervalSince1970 - 1),
                sessionUpdate("turn_completed")
            ],
            sessionID: "sibling-a",
            registerActive: false
        )
        try writeSubagentMeta(
            parentSessionID: "sibling-a",
            subagentID: "child",
            childCWD: "/tmp/child-work",
            status: "completed"
        )
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testUnlistedStaleInProgressSiblingEarlierThanOpenedAtIsHardTerminal() throws {
        let staleDate = currentDate.addingTimeInterval(-3_600)
        try writeSession(
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: staleDate.timeIntervalSince1970)
            ],
            sessionID: "sibling-a",
            modifiedAt: staleDate,
            registerActive: false
        )
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testUnlistedSiblingInDifferentCwdGroupDoesNotKeepRunning() throws {
        try writeSession(
            updates: [sessionUpdate("agent_thought_chunk")],
            cwd: "/tmp/other-group",
            sessionID: "sibling-a",
            registerActive: false
        )
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "listed-b"
        )
        try writeActiveSessions([
            [
                "session_id": "listed-b",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": iso8601String(currentDate)
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testUnfinishedSubagentMetaWithoutTranscriptStaysInProgress() throws {
        try writeSession(
            updates: [
                sessionUpdate("user_message_chunk", timestamp: currentDate.timeIntervalSince1970 - 20),
                sessionUpdate("turn_completed")
            ],
            sessionID: "parent"
        )
        try writeSubagentMeta(
            parentSessionID: "parent",
            subagentID: "child",
            childCWD: "/tmp/child-work",
            status: "running"
        )
        try writeActiveSessions([
            [
                "session_id": "parent",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
    }

    func testActiveSessionsJSONSelectsEncodedCWD() throws {
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            cwd: "/tmp/fixture",
            sessionID: "session-idle"
        )
        try writeSession(
            updates: [sessionUpdate("agent_message_chunk")],
            cwd: "/tmp/fixture",
            sessionID: "session-active",
            modifiedAt: currentDate.addingTimeInterval(1)
        )
        try writeActiveSessions([
            [
                "session_id": "session-active",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
    }

    func testParentTurnCompletedStillRunningWhenWorkflowIsActive() throws {
        try writeSession(
            updates: [
                sessionUpdate("user_message_chunk", timestamp: currentDate.timeIntervalSince1970 - 20),
                sessionUpdate("turn_completed")
            ],
            sessionID: "parent"
        )
        try writeWorkflowState(
            sessionID: "parent",
            runID: "wf_active",
            status: "active"
        )
        try writeActiveSessions([
            [
                "session_id": "parent",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testCompletedWorkflowAndFinishedChildrenAreIdle() throws {
        try writeSession(
            updates: [
                sessionUpdate("agent_thought_chunk", timestamp: currentDate.timeIntervalSince1970 - 1),
                sessionUpdate("turn_completed")
            ],
            sessionID: "parent"
        )
        try writeWorkflowState(
            sessionID: "parent",
            runID: "wf_done",
            status: "complete"
        )
        try writeSubagentMeta(
            parentSessionID: "parent",
            subagentID: "child",
            childCWD: "/tmp/child-work",
            status: "completed"
        )
        try writeActiveSessions([
            [
                "session_id": "parent",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testUnmatchedTaskBackgroundedStaysRunning() throws {
        try writeSession(updates: [
            sessionUpdate("user_message_chunk", timestamp: currentDate.timeIntervalSince1970 - 10),
            sessionUpdate("turn_completed"),
            taskBackgrounded("bg-1")
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testMatchedBackgroundTaskDoesNotKeepCompletedTurnRunning() throws {
        try writeSession(updates: [
            sessionUpdate("user_message_chunk", timestamp: currentDate.timeIntervalSince1970 - 10),
            sessionUpdate("turn_completed"),
            taskBackgrounded("bg-1"),
            taskCompleted("bg-1")
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testTaskCompletedDoesNotIdleActiveWorkflow() throws {
        try writeSession(
            updates: [
                sessionUpdate("user_message_chunk", timestamp: currentDate.timeIntervalSince1970 - 20),
                sessionUpdate("turn_completed"),
                taskBackgrounded("bg-1"),
                taskCompleted("bg-1")
            ],
            sessionID: "parent"
        )
        try writeWorkflowState(
            sessionID: "parent",
            runID: "wf_active",
            status: "active"
        )
        try writeActiveSessions([
            [
                "session_id": "parent",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
    }

    func testPausedWorkflowStaysRunning() throws {
        try writeSession(
            updates: [
                sessionUpdate("turn_completed")
            ],
            sessionID: "parent"
        )
        try writeWorkflowState(
            sessionID: "parent",
            runID: "wf_paused",
            status: "paused"
        )
        try writeActiveSessions([
            [
                "session_id": "parent",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.observation, .active)
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testProcessGoneIsIdleEvenWithActiveWorkflowState() throws {
        try writeSession(
            updates: [sessionUpdate("turn_completed")],
            sessionID: "parent"
        )
        try writeWorkflowState(
            sessionID: "parent",
            runID: "wf_active",
            status: "active"
        )
        try writeActiveSessions([
            [
                "session_id": "parent",
                "pid": 101,
                "cwd": "/tmp/fixture",
                "opened_at": "2026-09-05T00:00:00Z"
            ]
        ])

        let status = makeMonitor(
            processOutput: "101 1 ?? /usr/bin/python python grok.py"
        ).activityStatus()
        XCTAssertFalse(status.processRunning)
        XCTAssertEqual(status.observation, .hardTerminal)
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
    }

    func testProcessRunnerFailureAndNonZeroExitUseFalseFallback() {
        let throwingMonitor = GrokActivityMonitor(
            grokDirectory: fixtureDirectory,
            clock: { [weak self] in self?.currentDate ?? Date() },
            processRunner: { _, _ in throw FixtureError.processFailed }
        )
        XCTAssertEqual(throwingMonitor.status().processRunning, false)

        let failedMonitor = makeMonitor(
            processOutput: "101 1 ?? /Users/dev/.grok/bin/grok grok",
            terminationStatus: 1
        )
        XCTAssertEqual(failedMonitor.status().processRunning, false)
    }

    func testUnchangedLargeSiblingTailsAreReusedAcrossSlowPollingRounds() throws {
        try writeSession(updates: [sessionUpdate("turn_completed")])
        var event = sessionUpdate("turn_completed")
        event["padding"] = String(repeating: "fixture", count: 1_000)
        for index in 0..<64 {
            try writeSession(updates: Array(repeating: event, count: 30),
                             sessionID: "history-\(index)", registerActive: false)
        }
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        let reads = monitor.transcriptReadCount
        let parses = monitor.transcriptParseCount
        XCTAssertEqual(reads, 65)
        XCTAssertGreaterThan(parses, 64)
        for interval in [1.0, 5.0, 60.0] {
            currentDate.addTimeInterval(interval)
            XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
            XCTAssertEqual(monitor.transcriptReadCount, reads)
            XCTAssertEqual(monitor.transcriptParseCount, parses)
        }
    }

    func testTranscriptCacheInvalidatesForSameSizeMtimeChangeAndAppend() throws {
        let url = try writeSession(updates: [["type": "tool_call"]])
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        let originalSize = try Data(contentsOf: url).count
        currentDate.addTimeInterval(1)
        try writeJSONL([["type": "turn_completed"]], to: url, modifiedAt: currentDate)
        // Equalize the original file size with JSON whitespace before warming again.
        let completedData = try Data(contentsOf: url)
        try writeJSONL([["type": "tool_call"]], to: url, modifiedAt: currentDate)
        var activeData = try Data(contentsOf: url)
        activeData.append(Data(repeating: 0x20, count: completedData.count - originalSize))
        try activeData.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: currentDate], ofItemAtPath: url.path)
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        let reads = monitor.transcriptReadCount
        currentDate.addTimeInterval(1)
        try writeJSONL([["type": "turn_completed"]], to: url, modifiedAt: currentDate)
        XCTAssertEqual(try Data(contentsOf: url).count, activeData.count)
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.transcriptReadCount, reads + 1)
        currentDate.addTimeInterval(1)
        try writeJSONL([["type": "turn_completed"], ["type": "tool_call"]],
                       to: url, modifiedAt: currentDate)
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        XCTAssertEqual(monitor.transcriptReadCount, reads + 2)
    }

    func testStaleSiblingParentsAreRejectedWithoutReadingAndLiveWorkIsNeverCapped() throws {
        let staleDate = currentDate.addingTimeInterval(-3_600)
        try writeSession(updates: [sessionUpdate("turn_completed")])
        try writeActiveSessions([["session_id": "session", "cwd": "/tmp/fixture",
                                  "opened_at": currentDate.timeIntervalSince1970]])
        for index in 0..<64 {
            try writeSession(updates: [sessionUpdate("agent_thought_chunk", timestamp: staleDate.timeIntervalSince1970)],
                             sessionID: "history-\(index)", modifiedAt: staleDate, registerActive: false)
        }
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.transcriptReadCount, 1)
        XCTAssertEqual(monitor.transcriptParseCount, 1)
        currentDate.addTimeInterval(2)
        try writeSession(updates: [sessionUpdate("agent_thought_chunk")],
                         sessionID: "live", registerActive: false)
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        try writeSession(updates: [sessionUpdate("turn_completed")],
                         sessionID: "live", registerActive: false)
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        try writeSubagentMeta(parentSessionID: "history-63", subagentID: "child",
                              childCWD: "/tmp/child-work", status: "running")
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        try writeSubagentMeta(parentSessionID: "history-63", subagentID: "child",
                              childCWD: "/tmp/child-work", status: "completed")
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        for state in ["active", "running", "paused", "pausing"] {
            try writeWorkflowState(sessionID: "history-63", runID: "workflow", status: state)
            XCTAssertEqual(monitor.activityStatus().observation, .active, state)
        }
        try writeWorkflowState(sessionID: "history-63", runID: "workflow", status: "completed")
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.transcriptReadCount, 4)
    }

    func testStaleChildlessSiblingsSkipRelatedWorkAcrossLaterPolls() throws {
        let staleDate = currentDate.addingTimeInterval(-3_600)
        try writeSession(updates: [sessionUpdate("turn_completed")])
        try writeActiveSessions([["session_id": "session", "cwd": "/tmp/fixture",
                                  "opened_at": currentDate.timeIntervalSince1970]])
        for index in 0..<64 {
            try writeSession(
                updates: [sessionUpdate("agent_thought_chunk", timestamp: staleDate.timeIntervalSince1970)],
                sessionID: "history-\(index)",
                modifiedAt: staleDate,
                registerActive: false
            )
        }
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.relatedSessionSignalsCount, 1)
        XCTAssertEqual(monitor.transcriptReadCount, 1)
        XCTAssertEqual(monitor.transcriptParseCount, 1)
        XCTAssertEqual(monitor.childJSONReadCount, 0)
        var related = monitor.relatedSessionSignalsCount
        let reads = monitor.transcriptReadCount
        let parses = monitor.transcriptParseCount
        let childReads = monitor.childJSONReadCount
        for interval in [1.0, 5.0, 60.0] {
            currentDate.addTimeInterval(interval)
            XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
            related += 1
            XCTAssertEqual(monitor.relatedSessionSignalsCount, related)
            XCTAssertEqual(monitor.transcriptReadCount, reads)
            XCTAssertEqual(monitor.transcriptParseCount, parses)
            XCTAssertEqual(monitor.childJSONReadCount, childReads)
        }
    }

    func testCompletedSubagentMetaIsReusedWithoutRereadingOnLaterPolls() throws {
        let staleDate = currentDate.addingTimeInterval(-3_600)
        try writeSession(updates: [sessionUpdate("turn_completed")])
        try writeActiveSessions([["session_id": "session", "cwd": "/tmp/fixture",
                                  "opened_at": currentDate.timeIntervalSince1970]])
        for index in 0..<14 {
            try writeSession(
                updates: [sessionUpdate("turn_completed", timestamp: staleDate.timeIntervalSince1970)],
                sessionID: "history-\(index)",
                modifiedAt: staleDate,
                registerActive: false
            )
            try writeSubagentMeta(
                parentSessionID: "history-\(index)",
                subagentID: "child",
                childCWD: "/tmp/child-work",
                status: "completed"
            )
        }
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        let childReads = monitor.childJSONReadCount
        XCTAssertEqual(childReads, 14)
        let transcriptReads = monitor.transcriptReadCount
        for interval in [1.0, 5.0, 60.0] {
            currentDate.addTimeInterval(interval)
            XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
            XCTAssertEqual(monitor.childJSONReadCount, childReads)
            XCTAssertEqual(monitor.transcriptReadCount, transcriptReads)
        }
    }

    func testCachedLiveChildAndWorkflowStatusesStillBecomeActive() throws {
        let staleDate = currentDate.addingTimeInterval(-3_600)
        try writeSession(updates: [sessionUpdate("turn_completed")])
        try writeActiveSessions([["session_id": "session", "cwd": "/tmp/fixture",
                                  "opened_at": currentDate.timeIntervalSince1970]])
        try writeSession(
            updates: [sessionUpdate("turn_completed", timestamp: staleDate.timeIntervalSince1970)],
            sessionID: "history-live",
            modifiedAt: staleDate,
            registerActive: false
        )
        let monitor = makeMonitor()
        for state in ["active", "running", "paused", "pausing"] {
            try writeSubagentMeta(
                parentSessionID: "history-live",
                subagentID: "child",
                childCWD: "/tmp/child-work",
                status: state
            )
            XCTAssertEqual(monitor.activityStatus().observation, .active, state)
            let childReads = monitor.childJSONReadCount
            currentDate.addTimeInterval(1)
            XCTAssertEqual(monitor.activityStatus().observation, .active, state)
            XCTAssertEqual(monitor.childJSONReadCount, childReads)
        }
        try writeSubagentMeta(
            parentSessionID: "history-live",
            subagentID: "child",
            childCWD: "/tmp/child-work",
            status: "completed"
        )
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        for state in ["active", "running", "paused", "pausing"] {
            try writeWorkflowState(sessionID: "history-live", runID: "workflow", status: state)
            XCTAssertEqual(monitor.activityStatus().observation, .active, state)
            let childReads = monitor.childJSONReadCount
            currentDate.addTimeInterval(1)
            XCTAssertEqual(monitor.activityStatus().observation, .active, state)
            XCTAssertEqual(monitor.childJSONReadCount, childReads)
        }
        try writeWorkflowState(sessionID: "history-live", runID: "workflow", status: "completed")
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
    }

    func testEmptyActiveSessionsAndMissingProcessDoNotReadHistoricalTranscripts() throws {
        try writeSession(updates: [sessionUpdate("agent_thought_chunk")], registerActive: false)
        try writeActiveSessions([])
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.transcriptReadCount, 0)
        try upsertActiveSession(sessionID: "session", cwd: "/tmp/fixture")
        let absent = makeMonitor(processOutput: "")
        XCTAssertEqual(absent.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(absent.transcriptReadCount, 0)
    }

    func testByteTailCanStartInsideUnicodeAndStillFindFinalEvent() throws {
        var largeEvent = sessionUpdate("agent_thought_chunk")
        largeEvent["padding"] = String(repeating: "\u{1F600}", count: 60_000)
        try writeSession(updates: [largeEvent, sessionUpdate("turn_completed")])
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.transcriptParseCount, 1)
    }

    private func makeMonitor(
        processOutput: String = "101 1 ?? /Users/dev/.grok/bin/grok grok",
        terminationStatus: Int32 = 0
    ) -> GrokActivityMonitor {
        GrokActivityMonitor(
            grokDirectory: fixtureDirectory,
            clock: { [weak self] in self?.currentDate ?? Date() },
            processRunner: { _, _ in
                GrokProcessResult(
                    standardOutput: Data(processOutput.utf8),
                    terminationStatus: terminationStatus
                )
            }
        )
    }

    @discardableResult
    private func writeSubagentUpdates(
        parentSessionID: String,
        subagentID: String,
        cwd: String = "/tmp/fixture",
        updates: [[String: Any]],
        modifiedAt: Date? = nil
    ) throws -> URL {
        let encoded = GrokActivityMonitor.encodeSessionDirectoryName(cwd)
        let directory = fixtureDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(parentSessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(subagentID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("updates.jsonl")
        try writeJSONL(updates, to: url, modifiedAt: modifiedAt)
        return url
    }

    private func writeSubagentMeta(
        parentSessionID: String,
        subagentID: String,
        childCWD: String,
        status: String,
        cwd: String = "/tmp/fixture"
    ) throws {
        let encoded = GrokActivityMonitor.encodeSessionDirectoryName(cwd)
        let directory = fixtureDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(parentSessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(subagentID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let meta: [String: Any] = [
            "subagent_id": subagentID,
            "parent_session_id": parentSessionID,
            "child_session_id": subagentID,
            "child_cwd": childCWD,
            "status": status
        ]
        try JSONSerialization.data(withJSONObject: meta).write(
            to: directory.appendingPathComponent("meta.json")
        )
    }

    @discardableResult
    private func writeSession(
        updates: [[String: Any]],
        cwd: String = "/tmp/fixture",
        sessionID: String = "session",
        modifiedAt: Date? = nil,
        registerActive: Bool = true
    ) throws -> URL {
        let encoded = GrokActivityMonitor.encodeSessionDirectoryName(cwd)
        let sessionDirectory = fixtureDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        let url = sessionDirectory.appendingPathComponent("updates.jsonl")
        try writeJSONL(updates, to: url, modifiedAt: modifiedAt)
        if registerActive {
            try upsertActiveSession(sessionID: sessionID, cwd: cwd)
        }
        return url
    }

    private func upsertActiveSession(
        sessionID: String,
        cwd: String,
        pid: Int = 101
    ) throws {
        let url = fixtureDirectory.appendingPathComponent("active_sessions.json")
        var rows: [[String: Any]] = []
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rows = parsed
        }
        if rows.contains(where: {
            ($0["session_id"] as? String) == sessionID && ($0["cwd"] as? String) == cwd
        }) {
            return
        }
        rows.append([
            "session_id": sessionID,
            "pid": pid,
            "cwd": cwd,
            "opened_at": "2026-09-05T00:00:00Z"
        ])
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
    }

    private func writeJSONL(
        _ updates: [[String: Any]],
        to url: URL,
        modifiedAt: Date?
    ) throws {
        let lines = try updates.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt ?? currentDate],
            ofItemAtPath: url.path
        )
    }

    private func writeActiveSessions(_ rows: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(
            to: fixtureDirectory.appendingPathComponent("active_sessions.json")
        )
    }

    private func writeListedStubSession(
        sessionID: String,
        cwd: String = "/tmp/fixture"
    ) throws {
        let encoded = GrokActivityMonitor.encodeSessionDirectoryName(cwd)
        let sessionDirectory = fixtureDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func sessionUpdate(_ name: String, timestamp: TimeInterval? = nil) -> [String: Any] {
        [
            "timestamp": timestamp ?? currentDate.timeIntervalSince1970,
            "method": "session/update",
            "params": [
                "sessionId": "session",
                "update": [
                    "sessionUpdate": name
                ]
            ]
        ]
    }

    private func taskBackgrounded(
        _ taskID: String,
        timestamp: TimeInterval? = nil
    ) -> [String: Any] {
        [
            "timestamp": timestamp ?? currentDate.timeIntervalSince1970,
            "method": "_x.ai/session/update",
            "params": [
                "sessionId": "session",
                "update": [
                    "sessionUpdate": "task_backgrounded",
                    "tool_call_id": taskID,
                    "task_id": taskID,
                    "command": "sleep 30",
                    "cwd": "/tmp/fixture",
                    "output_file": "/tmp/fixture/terminal/\(taskID).log",
                    "description": "Background command"
                ]
            ]
        ]
    }

    private func taskCompleted(
        _ taskID: String,
        timestamp: TimeInterval? = nil
    ) -> [String: Any] {
        [
            "timestamp": timestamp ?? currentDate.timeIntervalSince1970,
            "method": "_x.ai/session/update",
            "params": [
                "sessionId": "session",
                "update": [
                    "sessionUpdate": "task_completed",
                    "task_snapshot": [
                        "task_id": taskID,
                        "command": "sleep 30",
                        "cwd": "/tmp/fixture"
                    ]
                ]
            ]
        ]
    }

    private func writeWorkflowState(
        sessionID: String,
        runID: String,
        status: String,
        cwd: String = "/tmp/fixture"
    ) throws {
        let encoded = GrokActivityMonitor.encodeSessionDirectoryName(cwd)
        let directory = fixtureDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let state: [String: Any] = [
            "version": 4,
            "state": [
                "run_id": runID,
                "revision": 1,
                "name": "deep-research",
                "status": status,
                "foreground": false
            ]
        ]
        try JSONSerialization.data(withJSONObject: state).write(
            to: directory.appendingPathComponent("state.json")
        )
    }

    private enum FixtureError: Error {
        case processFailed
    }
}
