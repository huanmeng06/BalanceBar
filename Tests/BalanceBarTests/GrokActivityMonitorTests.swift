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

    func testThoughtAndToolEventsAreActive() throws {
        try writeSession(updates: [
            sessionUpdate("user_message_chunk"),
            sessionUpdate("agent_thought_chunk")
        ])
        XCTAssertTrue(makeMonitor().status().taskRunning)

        try writeSession(updates: [
            sessionUpdate("tool_call")
        ], sessionID: "tool")
        XCTAssertTrue(makeMonitor().status().taskRunning)
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
    private func writeSession(
        updates: [[String: Any]],
        cwd: String = "/tmp/fixture",
        sessionID: String = "session",
        modifiedAt: Date? = nil
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
        let lines = try updates.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt ?? currentDate],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writeActiveSessions(_ rows: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(
            to: fixtureDirectory.appendingPathComponent("active_sessions.json")
        )
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

    private enum FixtureError: Error {
        case processFailed
    }
}
