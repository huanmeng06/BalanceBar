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
