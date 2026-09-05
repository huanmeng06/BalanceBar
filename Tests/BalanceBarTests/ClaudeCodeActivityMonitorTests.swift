import Foundation
import XCTest
@testable import BalanceBar

final class ClaudeCodeActivityMonitorTests: XCTestCase {
    private var fixtureDirectory: URL!
    private var currentDate = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        currentDate = Date(timeIntervalSince1970: 2_000_000_000)
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-ClaudeActivityMonitor-\(UUID().uuidString)", isDirectory: true)
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
        let monitor = makeMonitor(processOutput: "101 1 ?? /usr/local/bin/claude claude")

        let status = monitor.status()

        XCTAssertTrue(status.processRunning)
        XCTAssertFalse(status.taskRunning)
    }

    func testProcessStatusExposesTTYFromPS() {
        let status = makeMonitor(
            processOutput: "101 1 ttys002 /usr/local/bin/claude claude"
        ).activityStatus()
        XCTAssertTrue(status.processRunning)
        XCTAssertEqual(status.ttys, ["ttys002"])
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testProcessPresenceDoesNotRequireSessionScan() {
        let monitor = makeMonitor(
            processOutput: "101 1 ttys002 /usr/local/bin/claude claude"
        )
        let presence = monitor.processPresence()
        XCTAssertTrue(presence.running)
        XCTAssertEqual(presence.ttys, ["ttys002"])
        XCTAssertEqual(monitor.status().processRunning, true)
        XCTAssertFalse(monitor.status().taskRunning)
    }

    func testProcessAbsenceDoesNotReadProjects() {
        let monitor = makeMonitor(processOutput: "101 1 ?? /usr/bin/python worker.py")

        let status = monitor.status()

        XCTAssertFalse(status.processRunning)
        XCTAssertFalse(status.taskRunning)
    }

    func testProcessRunnerFailureAndNonZeroExitUseFalseFallback() {
        let throwingMonitor = ClaudeCodeActivityMonitor(
            projectsDirectory: fixtureDirectory,
            clock: { [weak self] in self?.currentDate ?? Date() },
            processRunner: { _, _ in throw FixtureError.processFailed }
        )
        XCTAssertEqual(throwingMonitor.status().processRunning, false)

        let failedMonitor = makeMonitor(
            processOutput: "101 1 ?? /usr/local/bin/claude claude",
            terminationStatus: 1
        )
        XCTAssertEqual(failedMonitor.status().processRunning, false)
    }

    func testThinkingAndToolUseEventsAreActive() throws {
        let thinkingURL = try writeSession([
            try assistantEvent(stopReason: nil, contentTypes: ["thinking"])
        ], filename: "thinking.jsonl")
        let thinkingMonitor = makeMonitor()
        let thinkingStatus = thinkingMonitor.activityStatus()
        XCTAssertTrue(thinkingStatus.observation.legacyIsTaskRunning, thinkingURL.path)
        XCTAssertTrue(thinkingStatus.trueTurnEvidence)

        let toolUseURL = try writeSession([
            try assistantEvent(stopReason: "tool_use", contentTypes: [])
        ], filename: "tool-use.jsonl", modifiedAt: currentDate)
        let toolUseMonitor = makeMonitor()
        let toolStatus = toolUseMonitor.activityStatus()
        XCTAssertTrue(toolStatus.observation.legacyIsTaskRunning, toolUseURL.path)
        XCTAssertTrue(toolStatus.trueTurnEvidence)
    }

    func testToolResultOnlyAfterCompletedAssistantDoesNotRestartTask() throws {
        _ = try writeSession([
            try assistantEvent(stopReason: "end_turn", contentTypes: []),
            try userEvent(contentTypes: ["tool_result"])
        ])

        let status = makeMonitor().status()

        XCTAssertTrue(status.processRunning)
        XCTAssertFalse(status.taskRunning)
    }

    func testClaudeHardTerminalIsExposedSeparatelyFromAmbiguousIdle() throws {
        _ = try writeSession([
            try assistantEvent(stopReason: "end_turn", contentTypes: [])
        ])
        XCTAssertEqual(makeMonitor().activityStatus().observation, .hardTerminal)

        let idleDirectory = fixtureDirectory.appendingPathComponent("idle", isDirectory: true)
        try FileManager.default.createDirectory(at: idleDirectory, withIntermediateDirectories: true)
        let idleMonitor = ClaudeCodeActivityMonitor(
            projectsDirectory: idleDirectory,
            clock: { [weak self] in self?.currentDate ?? Date() },
            processRunner: { _, _ in
                ClaudeProcessResult(
                    standardOutput: Data("101 1 ?? /usr/local/bin/claude claude".utf8),
                    terminationStatus: 0
                )
            }
        )
        XCTAssertEqual(idleMonitor.activityStatus().observation, .ambiguousIdle)
    }

    func testExpiredTranscriptIsInactive() throws {
        _ = try writeSession(
            [try assistantEvent(stopReason: nil, contentTypes: [])],
            modifiedAt: currentDate.addingTimeInterval(-16)
        )

        let status = makeMonitor().activityStatus()
        XCTAssertFalse(status.observation.legacyIsTaskRunning)
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testRecentWriteWithoutThinkingIsNotTrueTurnEvidence() throws {
        _ = try writeSession(
            [try assistantEvent(stopReason: nil, contentTypes: [])],
            modifiedAt: currentDate
        )
        let status = makeMonitor().activityStatus()
        XCTAssertTrue(status.observation.legacyIsTaskRunning)
        XCTAssertFalse(status.trueTurnEvidence)
    }

    func testDamagedTranscriptIsInactive() throws {
        let projectDirectory = fixtureDirectory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let sessionURL = projectDirectory.appendingPathComponent("damaged.jsonl")
        try Data([0x7B, 0xFF, 0x0A]).write(to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: currentDate],
            ofItemAtPath: sessionURL.path
        )

        XCTAssertFalse(makeMonitor().status().taskRunning)
    }

    func testInterruptedEventStopsAnOtherwiseActiveTranscript() throws {
        _ = try writeSession([
            try assistantEvent(stopReason: "tool_use", contentTypes: []),
            try json(["type": "user", "interruptedMessageId": "fixture-message"])
        ])

        XCTAssertFalse(makeMonitor().status().taskRunning)
    }

    func testNewestMainSessionWinsAndSubagentsAreIgnored() throws {
        let oldSession = try writeSession(
            [try assistantEvent(stopReason: "tool_use", contentTypes: [])],
            filename: "old.jsonl",
            modifiedAt: currentDate.addingTimeInterval(-1)
        )
        let subagentsDirectory = oldSession.deletingLastPathComponent().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagentsDirectory, withIntermediateDirectories: true)
        let subagentURL = subagentsDirectory.appendingPathComponent("newest.jsonl")
        try Data(try json(["type": "assistant", "message": ["stop_reason": "end_turn"]]).utf8)
            .write(to: subagentURL)
        try FileManager.default.setAttributes(
            [.modificationDate: currentDate.addingTimeInterval(1)],
            ofItemAtPath: subagentURL.path
        )

        _ = try writeSession(
            [try assistantEvent(stopReason: "end_turn", contentTypes: [])],
            filename: "newest.jsonl",
            modifiedAt: currentDate
        )

        XCTAssertFalse(makeMonitor().status().taskRunning)
    }

    func testProcessAndSessionCachesRespectInjectedClock() throws {
        _ = try writeSession([
            try assistantEvent(stopReason: "tool_use", contentTypes: [])
        ])
        var processOutput = "101 1 ?? /usr/local/bin/claude claude"
        var processCalls = 0
        let monitor = ClaudeCodeActivityMonitor(
            projectsDirectory: fixtureDirectory,
            clock: { [weak self] in self?.currentDate ?? Date() },
            processRunner: { _, _ in
                processCalls += 1
                return ClaudeProcessResult(
                    standardOutput: Data(processOutput.utf8),
                    terminationStatus: 0
                )
            }
        )

        XCTAssertTrue(monitor.status().taskRunning)
        processOutput = "101 1 ?? /usr/bin/python worker.py"
        currentDate = currentDate.addingTimeInterval(0.5)
        XCTAssertTrue(monitor.status().taskRunning)
        XCTAssertEqual(processCalls, 1)

        currentDate = currentDate.addingTimeInterval(0.6)
        XCTAssertFalse(monitor.status().processRunning)
        XCTAssertEqual(processCalls, 2)
    }

    func testSessionPathCacheExpiresAfterTwoSeconds() throws {
        _ = try writeSession(
            [try assistantEvent(stopReason: "tool_use", contentTypes: [])],
            filename: "active.jsonl"
        )
        let monitor = makeMonitor()

        XCTAssertTrue(monitor.status().taskRunning)

        currentDate = currentDate.addingTimeInterval(1.1)
        _ = try writeSession(
            [try assistantEvent(stopReason: "end_turn", contentTypes: [])],
            filename: "completed.jsonl",
            modifiedAt: currentDate
        )
        XCTAssertTrue(monitor.status().taskRunning)

        currentDate = currentDate.addingTimeInterval(1.0)
        XCTAssertFalse(monitor.status().taskRunning)
    }

    private func makeMonitor(
        processOutput: String = "101 1 ?? /usr/local/bin/claude claude",
        terminationStatus: Int32 = 0
    ) -> ClaudeCodeActivityMonitor {
        ClaudeCodeActivityMonitor(
            projectsDirectory: fixtureDirectory,
            clock: { [weak self] in self?.currentDate ?? Date() },
            processRunner: { _, _ in
                ClaudeProcessResult(
                    standardOutput: Data(processOutput.utf8),
                    terminationStatus: terminationStatus
                )
            }
        )
    }

    @discardableResult
    private func writeSession(
        _ events: [String],
        filename: String = "session.jsonl",
        modifiedAt: Date? = nil
    ) throws -> URL {
        let projectDirectory = fixtureDirectory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let sessionURL = projectDirectory.appendingPathComponent(filename)
        let text = events.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt ?? currentDate],
            ofItemAtPath: sessionURL.path
        )
        return sessionURL
    }

    private func assistantEvent(stopReason: String?, contentTypes: [String]) throws -> String {
        var message: [String: Any] = [
            "content": contentTypes.map { ["type": $0] }
        ]
        message["stop_reason"] = stopReason as Any
        return try json(["type": "assistant", "message": message])
    }

    private func userEvent(contentTypes: [String]) throws -> String {
        try json([
            "type": "user",
            "message": ["content": contentTypes.map { ["type": $0] }]
        ])
    }

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private enum FixtureError: Error {
        case processFailed
    }
}
