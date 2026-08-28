import Foundation
import SQLite3
import XCTest
@testable import BalanceBar

final class CodexActivityMonitorTests: XCTestCase {
    private var fixtureDirectory: URL!
    private var currentDate = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        currentDate = Date(timeIntervalSince1970: 2_000_000_000)
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-CodexActivityMonitor-\(UUID().uuidString)", isDirectory: true)
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

    func testActiveTaskIsDetected() throws {
        let sessionURL = try writeSession([eventMessage("task_started")])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertTrue(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testLongRolloutTailDetectsOngoingReasoningAndToolActivityWithoutStart() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            String(repeating: "padding", count: 50_000),
            eventMessage("model_switched"),
            eventMessage("reconnected"),
            eventMessage("agent_reasoning"),
            responseItem(type: "reasoning"),
            responseItem(type: "function_call"),
            responseItem(type: "function_call_output")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertTrue(
            makeMonitor().isTaskRunning(now: currentDate),
            "continuation activity in the tail must keep a long task active after its start scrolls out"
        )
    }

    func testRecentAgentMessageWithoutExplicitActivityIsInactive() throws {
        let sessionURL = try writeSession([
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"cached assistant output","phase":"commentary"}}"#
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testModelSwitchAndReconnectReasoningKeepsTaskActive() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("model_switched"),
            eventMessage("reconnected"),
            eventMessage("agent_reasoning")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertTrue(
            makeMonitor().isTaskRunning(now: currentDate),
            "reasoning during a model switch/reconnect keeps the unfinished task active"
        )
    }

    func testTerminalSuppressesTrailingReasoningAndToolActivity() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("task_complete"),
            eventMessage("agent_reasoning"),
            responseItem(type: "reasoning"),
            responseItem(type: "function_call"),
            responseItem(type: "function_call_output"),
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testResponseItemCompletedStatusSuppressesTrailingActivity() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            responseItem(type: "reasoning"),
            responseItem(type: "function_call"),
            responseItem(type: "function_call_output"),
            responseItem(status: "completed"),
            responseItem(type: "reasoning"),
            responseItem(type: "function_call_output")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(
            makeMonitor().isTaskRunning(now: currentDate),
            "a completed response_item must remain terminal despite trailing activity"
        )
    }

    func testCompletedCustomToolCallKeepsTaskRunningUntilFinalResponse() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("agent_reasoning")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)
        let monitor = makeMonitor()

        XCTAssertTrue(monitor.isTaskRunning(now: currentDate))

        try appendSession([
            responseItem(type: "custom_tool_call", status: "completed")
        ], to: sessionURL)
        currentDate = currentDate.addingTimeInterval(0.1)
        XCTAssertTrue(
            monitor.isTaskRunning(now: currentDate),
            "completion of one custom tool call must not end the containing task"
        )

        try appendSession([
            responseItem(type: "custom_tool_call_output")
        ], to: sessionURL)
        currentDate = currentDate.addingTimeInterval(0.1)
        XCTAssertTrue(
            monitor.isTaskRunning(now: currentDate),
            "custom tool output must keep the task active after the call completes"
        )

        try appendSession([responseItem(phase: "final")], to: sessionURL)
        currentDate = currentDate.addingTimeInterval(0.1)
        XCTAssertFalse(
            monitor.isTaskRunning(now: currentDate),
            "the genuine final response must still stop activity"
        )
    }

    func testCustomToolActivityAfterTerminalDoesNotReopenTask() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            responseItem(phase: "final"),
            responseItem(type: "custom_tool_call", status: "completed"),
            responseItem(type: "custom_tool_call_output")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(
            makeMonitor().isTaskRunning(now: currentDate),
            "tool items trailing a genuine terminal response must remain inactive"
        )
    }

    func testAllResponseItemTerminalStatusesSuppressTrailingActivity() throws {
        for status in ["completed", "failed", "cancelled", "canceled", "incomplete"] {
            let directory = fixtureDirectory.appendingPathComponent(status, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sessionURL = try writeSession([
                eventMessage("task_started"),
                responseItem(type: "reasoning"),
                responseItem(status: status),
                responseItem(type: "function_call_output")
            ], in: directory)
            try makeStateDatabase(rolloutPath: sessionURL.path, in: directory)

            XCTAssertFalse(
                CodexActivityMonitor(codexDirectory: directory) { [weak self] in
                    self?.currentDate ?? .distantPast
                }.isTaskRunning(now: currentDate),
                "response_item status=\(status) must be terminal"
            )
        }
    }

    func testTerminalBeforeLargeTrailingReasoningAndToolOutputRemainsInactive() throws {
        let trailingReasoning = Array(
            repeating: responseItem(type: "reasoning"),
            count: 5_000
        ).joined(separator: "\n")
        XCTAssertGreaterThan(trailingReasoning.utf8.count, 256 * 1024)

        let sessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("task_complete"),
            trailingReasoning,
            responseItem(type: "function_call"),
            responseItem(type: "function_call_output")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(
            makeMonitor().isTaskRunning(now: currentDate),
            "a terminal marker before the activity tail must suppress all trailing activity"
        )
    }

    func testStaleUnterminatedRolloutIsInactive() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("agent_reasoning"),
            responseItem(type: "function_call_output")
        ])
        try setSessionModificationDate(sessionURL, to: currentDate.addingTimeInterval(-601))
        try makeStateDatabase(rolloutPath: sessionURL.path, updatedAt: epoch - 601)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testRecentStateWithStaleSessionFileIsInactive() throws {
        let sessionURL = try writeSession([eventMessage("task_started")])
        try setSessionModificationDate(sessionURL, to: currentDate.addingTimeInterval(-601))
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testStaleStateWithRecentSessionFileIsInactive() throws {
        let sessionURL = try writeSession([eventMessage("task_started")])
        try makeStateDatabase(rolloutPath: sessionURL.path, updatedAt: epoch - 601)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testIdleLaunchWithRecentTerminalAndStaleUnterminatedRolloutsIsInactive() throws {
        var rollouts: [RolloutFixture] = []
        for index in 0..<23 {
            let sessionURL = try writeSession([eventMessage("task_complete")])
            rollouts.append(RolloutFixture(path: sessionURL.path, updatedAt: epoch - Int64(index + 1)))
        }
        let staleSessionURL = try writeSession([eventMessage("task_started")])
        try setSessionModificationDate(staleSessionURL, to: currentDate.addingTimeInterval(-601))
        rollouts.append(RolloutFixture(path: staleSessionURL.path, updatedAt: epoch - 601))
        try makeStateDatabase(rollouts: rollouts)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testActiveOlderRolloutIsNotHiddenByNewerStoppedRollouts() throws {
        var rollouts: [RolloutFixture] = []
        for index in 0..<24 {
            let sessionURL = try writeSession([
                eventMessage("task_started"),
                eventMessage("task_stopped")
            ])
            rollouts.append(
                RolloutFixture(path: sessionURL.path, updatedAt: epoch - Int64(index + 1))
            )
        }

        let activeSessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("agent_reasoning")
        ])
        rollouts.append(
            RolloutFixture(path: activeSessionURL.path, updatedAt: epoch - 60)
        )
        try makeStateDatabase(rollouts: rollouts)

        XCTAssertTrue(
            makeMonitor().isTaskRunning(now: currentDate),
            "an active task must keep the aggregate state running even when 24 newer stopped tasks exist"
        )
    }

    func testIdleLaunchWithRecentlyCompletedLogIsInactive() throws {
        let timestamp = epoch - 5
        try makeLogsDatabase(rows: [
            (threadID: "fixture-thread", timestamp: timestamp, body: #"{"type":"response.output_text.delta"}"#),
            (threadID: "fixture-thread", timestamp: timestamp, body: #"{"type":"response.completed","response":{"status":"completed"}}"#)
        ])

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testIdleRecentOutputWithoutExplicitInProgressSignalIsInactive() throws {
        try makeLogsDatabase(rows: [
            (threadID: "fixture-thread", timestamp: epoch - 5, body: #"{"type":"response.output_text.delta"}"#)
        ])

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testActiveLogWithExplicitInProgressSignalIsDetected() throws {
        try makeLogsDatabase(rows: [
            (threadID: "fixture-thread", timestamp: epoch - 5, body: #"{"type":"response.in_progress","response":{"status":"in_progress"}}"#),
            (threadID: "fixture-thread", timestamp: epoch - 1, body: #"{"type":"response.output_text.delta"}"#)
        ])

        XCTAssertTrue(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testRecentTerminalRolloutOverridesDelayedLogActivity() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("task_complete")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)
        try makeLogsDatabase(rows: [
            (threadID: "fixture-thread", timestamp: epoch - 5, body: #"{"type":"response.in_progress"}"#),
            (threadID: "fixture-thread", timestamp: epoch - 1, body: #"{"type":"response.output_text.delta"}"#)
        ])

        XCTAssertFalse(
            makeMonitor().isTaskRunning(now: currentDate),
            "a delayed log signal must not override a recent terminal rollout event"
        )
    }

    func testResponseCompletionOverridesPriorInProgressActivity() throws {
        try makeLogsDatabase(rows: [
            (threadID: "fixture-thread", timestamp: epoch - 5, body: #"{"type":"response.in_progress"}"#),
            (threadID: "fixture-thread", timestamp: epoch - 1, body: #"{"type":"response.output_text.delta"}"#),
            (threadID: "fixture-thread", timestamp: epoch - 1, body: #"{"type":"response.completed"}"#)
        ])

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testIdleRecentResponseItemWithoutTaskStartIsInactive() throws {
        let sessionURL = try writeSession([
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[]}}"#
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testCompletedRolloutWithTrailingResponseItemIsInactive() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("task_complete"),
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testCompletionEventsStopRolloutActivity() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("task_completed"),
            responseItem(phase: "final")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testFinalAgentMessageStopsRolloutActivity() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"done","phase":"final_answer","memory_citation":null}}"#
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testContextCompactionReopensActivityAfterFinalAnswer() throws {
        let sessionURL = try writeSession([
            responseItem(phase: "final_answer"),
            topLevelEvent("compacted"),
            topLevelEvent("world_state"),
            topLevelEvent("turn_context"),
            topLevelEvent("context_compacted"),
            eventMessage("agent_reasoning"),
            responseItem(type: "reasoning"),
            eventMessage("function_call"),
            responseItem(type: "function_call_output")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertTrue(
            makeMonitor().isTaskRunning(now: currentDate),
            "explicit reasoning and tool activity after context compaction must reopen the task"
        )
    }

    func testContextCompactionWithoutExplicitActivityRemainsInactive() throws {
        let sessionURL = try writeSession([
            responseItem(phase: "final_answer"),
            topLevelEvent("compacted"),
            topLevelEvent("world_state"),
            topLevelEvent("turn_context"),
            eventMessage("context_compacted"),
            eventMessage("agent_message")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(
            makeMonitor().isTaskRunning(now: currentDate),
            "context compaction and ordinary commentary must not be treated as activity"
        )
    }

    func testTerminalAfterContextCompactionStillSuppressesTrailingActivity() throws {
        let sessionURL = try writeSession([
            responseItem(phase: "final_answer"),
            topLevelEvent("context_compacted"),
            responseItem(type: "reasoning"),
            eventMessage("task_complete"),
            responseItem(type: "function_call_output")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertFalse(
            makeMonitor().isTaskRunning(now: currentDate),
            "a genuine terminal event after compaction must suppress later trailing activity"
        )
    }

    func testOfficialModelStartReasoningAndTerminal() throws {
        let sessionURL = try writeSession([
            eventMessage("user_message"),
            eventMessage("agent_reasoning"),
            responseItem(type: "reasoning"),
            responseItem(type: "function_call"),
            responseItem(type: "function_call_output"),
            responseItem(phase: "final")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)
        let monitor = makeMonitor()

        XCTAssertFalse(
            monitor.isTaskRunning(now: currentDate),
            "the official-model terminal response must win over its preceding activity"
        )

        let activeSessionURL = try writeSession([
            eventMessage("user_message"),
            eventMessage("agent_reasoning")
        ])
        try updateStateDatabase(rolloutPath: activeSessionURL.path)
        currentDate = currentDate.addingTimeInterval(1.1)

        XCTAssertTrue(monitor.isTaskRunning(now: currentDate))
    }

    func testMonitorResultDrivesRotatingMenuBarViewAndPreferencePolicy() throws {
        let sessionURL = try writeSession([
            eventMessage("task_started"),
            eventMessage("agent_reasoning")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)
        let monitor = makeMonitor()
        let imageView = RotatingTemplateImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        imageView.setSourceImage(NSImage(size: NSSize(width: 16, height: 16)))

        XCTAssertTrue(monitor.isTaskRunning(now: currentDate))
        XCTAssertTrue(MenuBarActivityAnimationPolicy.shouldAnimate(taskRunning: true, preferenceEnabled: true))
        imageView.startRotating()
        XCTAssertTrue(imageView.isRotating)

        XCTAssertFalse(MenuBarActivityAnimationPolicy.shouldAnimate(taskRunning: true, preferenceEnabled: false))
        imageView.stopRotating()
        XCTAssertFalse(imageView.isRotating)

        try appendSession([responseItem(phase: "final")], to: sessionURL)
        currentDate = currentDate.addingTimeInterval(1.1)
        XCTAssertFalse(monitor.isTaskRunning(now: currentDate))
        imageView.stopRotating()
        XCTAssertFalse(imageView.isRotating)
    }

    func testTransitionToFinalThenNextPollIsInactive() throws {
        let sessionURL = try writeSession([eventMessage("task_started")])
        try makeStateDatabase(rolloutPath: sessionURL.path)
        let monitor = makeMonitor()

        XCTAssertTrue(monitor.isTaskRunning(now: currentDate))

        try appendSession([responseItem(phase: "final")], to: sessionURL)
        currentDate = currentDate.addingTimeInterval(1.1)

        XCTAssertFalse(monitor.isTaskRunning(now: currentDate))
    }

    func testSessionCacheInvalidatesAcrossActiveToCompletedTransition() throws {
        let sessionURL = try writeSession([eventMessage("task_started")])
        try makeStateDatabase(rolloutPath: sessionURL.path)
        let monitor = makeMonitor()

        XCTAssertTrue(monitor.isTaskRunning(now: currentDate))

        try appendSession([eventMessage("task_complete")], to: sessionURL)
        currentDate = currentDate.addingTimeInterval(0.1)

        XCTAssertFalse(
            monitor.isTaskRunning(now: currentDate),
            "a changed rollout file must invalidate the cached active result before the path cache refreshes"
        )
    }

    func testSessionCacheResetsWhenFileIsRewrittenAtTheSameSize() throws {
        let sessionURL = try writeSession([eventMessage("task_started")])
        try makeStateDatabase(rolloutPath: sessionURL.path)
        let monitor = makeMonitor()

        XCTAssertTrue(monitor.isTaskRunning(now: currentDate))

        // task_started and task_stopped are intentionally equal-length JSONL
        // records. A same-size rewrite must not make the incremental scanner
        // seek past the replacement terminal event.
        let replacement = eventMessage("task_stopped") + "\n"
        try Data(replacement.utf8).write(to: sessionURL)
        currentDate = currentDate.addingTimeInterval(0.1)
        try setSessionModificationDate(sessionURL, to: currentDate)

        XCTAssertFalse(monitor.isTaskRunning(now: currentDate))
    }

    func testExpiredLogActivityIsIgnored() throws {
        try makeLogsDatabase(rows: [
            (threadID: "fixture-thread", timestamp: epoch - 601, body: #"{"type":"response.output_text.delta"}"#)
        ])

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testRecentLogActivityStopsAfterCompletionEvent() throws {
        try makeLogsDatabase(rows: [
            (threadID: "fixture-thread", timestamp: epoch - 5, body: #"{"type":"response.output_text.delta"}"#),
            (threadID: "fixture-thread", timestamp: epoch - 4, body: #"{"type":"task_complete"}"#)
        ])

        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testMissingDatabasesReturnInactive() {
        XCTAssertFalse(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testMalformedJSONLDoesNotHideValidActivity() throws {
        let sessionURL = try writeSession([
            "this is not JSONL",
            eventMessage("task_started")
        ])
        try makeStateDatabase(rolloutPath: sessionURL.path)

        XCTAssertTrue(makeMonitor().isTaskRunning(now: currentDate))
    }

    func testPathCacheUsesInjectedClockAndRefreshesAfterItsOneSecondWindow() throws {
        let firstSessionURL = try writeSession([eventMessage("task_started")])
        let secondSessionURL = try writeSession([eventMessage("task_completed")])
        try makeStateDatabase(rolloutPath: firstSessionURL.path)
        let monitor = makeMonitor()

        XCTAssertTrue(monitor.isTaskRunning(now: currentDate))

        try updateStateDatabase(rolloutPath: secondSessionURL.path)
        currentDate = currentDate.addingTimeInterval(0.5)
        XCTAssertTrue(monitor.isTaskRunning(now: currentDate), "the cached rollout path should remain visible for one second")

        currentDate = currentDate.addingTimeInterval(0.6)
        XCTAssertFalse(monitor.isTaskRunning(now: currentDate), "the path cache should refresh after one second")
    }

    private var epoch: Int64 {
        Int64(currentDate.timeIntervalSince1970)
    }

    private func makeMonitor() -> CodexActivityMonitor {
        CodexActivityMonitor(codexDirectory: fixtureDirectory) { [weak self] in
            self?.currentDate ?? .distantPast
        }
    }

    @discardableResult
    private func writeSession(_ lines: [String], in directory: URL? = nil) throws -> URL {
        let targetDirectory = directory ?? fixtureDirectory!
        let url = targetDirectory.appendingPathComponent("session-\(UUID().uuidString).jsonl")
        let contents = lines.joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: url)
        try setSessionModificationDate(url, to: currentDate)
        return url
    }

    private func appendSession(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        try setSessionModificationDate(url, to: currentDate)
    }

    private func setSessionModificationDate(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func eventMessage(_ type: String) -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"}}"
    }

    private func topLevelEvent(_ type: String) -> String {
        "{\"type\":\"\(type)\"}"
    }

    private func responseItem(phase: String) -> String {
        "{\"type\":\"response_item\",\"payload\":{\"phase\":\"\(phase)\"}}"
    }

    private func responseItem(type: String) -> String {
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"\(type)\"}}"
    }

    private func responseItem(type: String, status: String) -> String {
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"\(type)\",\"status\":\"\(status)\"}}"
    }

    private func responseItem(status: String, type: String = "message") -> String {
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"\(type)\",\"status\":\"\(status)\"}}"
    }

    private struct RolloutFixture {
        let path: String
        let updatedAt: Int64
    }

    private func makeStateDatabase(
        rolloutPath: String,
        updatedAt: Int64? = nil,
        in directory: URL? = nil
    ) throws {
        try makeStateDatabase(
            rollouts: [RolloutFixture(path: rolloutPath, updatedAt: updatedAt ?? epoch)],
            in: directory
        )
    }

    private func makeStateDatabase(
        rollouts: [RolloutFixture],
        in directory: URL? = nil
    ) throws {
        try withDatabase(named: "state_1.sqlite", in: directory) { database in
            try execute(database, sql: "CREATE TABLE threads (rollout_path TEXT, updated_at INTEGER, updated_at_ms INTEGER)")
            for rollout in rollouts {
                try insertThread(database, rolloutPath: rollout.path, updatedAt: rollout.updatedAt)
            }
        }
    }

    private func updateStateDatabase(rolloutPath: String) throws {
        try withDatabase(named: "state_1.sqlite") { database in
            try execute(database, sql: "DELETE FROM threads")
            try insertThread(database, rolloutPath: rolloutPath)
        }
    }

    private func insertThread(_ database: OpaquePointer, rolloutPath: String, updatedAt: Int64? = nil) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO threads (rollout_path, updated_at, updated_at_ms) VALUES (?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw fixtureError("failed to prepare state fixture insert")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, rolloutPath, -1, Self.sqliteTransient)
        let updatedAt = updatedAt ?? epoch
        sqlite3_bind_int64(statement, 2, updatedAt)
        sqlite3_bind_int64(statement, 3, updatedAt * 1000)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw fixtureError("failed to insert state fixture row")
        }
    }

    private func makeLogsDatabase(
        rows: [(threadID: String, timestamp: Int64, body: String)]
    ) throws {
        try withDatabase(named: "logs_1.sqlite") { database in
            try execute(database, sql: "CREATE TABLE logs (thread_id TEXT, ts INTEGER, feedback_log_body TEXT)")
            try execute(database, sql: "CREATE INDEX idx_logs_ts ON logs(ts)")
            for row in rows {
                try insertLog(database, threadID: row.threadID, timestamp: row.timestamp, body: row.body)
            }
        }
    }

    private func insertLog(
        _ database: OpaquePointer,
        threadID: String,
        timestamp: Int64,
        body: String
    ) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO logs (thread_id, ts, feedback_log_body) VALUES (?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw fixtureError("failed to prepare logs fixture insert")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, threadID, -1, Self.sqliteTransient)
        sqlite3_bind_int64(statement, 2, timestamp)
        sqlite3_bind_text(statement, 3, body, -1, Self.sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw fixtureError("failed to insert logs fixture row")
        }
    }

    private func withDatabase<T>(
        named name: String,
        in directory: URL? = nil,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        let url = (directory ?? fixtureDirectory!).appendingPathComponent(name)
        let code = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard code == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw fixtureError("failed to open sqlite fixture; code=\(code)")
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
        }
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            throw fixtureError("fixture SQL failed; code=\(code); error=\(message)")
        }
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "BalanceBar.CodexActivityMonitorTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
