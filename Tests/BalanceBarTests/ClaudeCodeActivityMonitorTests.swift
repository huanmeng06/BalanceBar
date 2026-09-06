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

    func testProcessAbsenceDoesNotReadProjects() throws {
        _ = try writeSession([
            try assistantEvent(stopReason: "tool_use", contentTypes: [])
        ])
        let monitor = makeMonitor(processOutput: "101 1 ?? /usr/bin/python worker.py")

        let status = monitor.status()

        XCTAssertFalse(status.processRunning)
        XCTAssertFalse(status.taskRunning)
        XCTAssertEqual(monitor.sessionScanCount, 0)
        XCTAssertEqual(monitor.transcriptReadCount, 0)
    }

    func testProcessRunnerFailureAndNonZeroExitKeepLastTrustedPresence() throws {
        _ = try writeSession([
            try assistantEvent(stopReason: "tool_use", contentTypes: [])
        ])

        let throwingMonitor = ClaudeCodeActivityMonitor(
            projectsDirectory: fixtureDirectory,
            clock: { [weak self] in self?.currentDate ?? Date() },
            processRunner: { _, _ in throw FixtureError.processFailed }
        )
        let firstThrow = throwingMonitor.activityStatus()
        XCTAssertEqual(firstThrow.processRunning, false)
        XCTAssertEqual(firstThrow.observation, .hardTerminal)
        XCTAssertEqual(throwingMonitor.sessionScanCount, 0)

        let firstNonZero = makeMonitor(
            processOutput: "101 1 ?? /usr/local/bin/claude claude",
            terminationStatus: 1
        ).activityStatus()
        XCTAssertEqual(firstNonZero.processRunning, false)
        XCTAssertEqual(firstNonZero.observation, .hardTerminal)

        var processOutput = "101 1 ttys002 /usr/local/bin/claude claude"
        var terminationStatus: Int32 = 0
        var shouldThrow = false
        var processCalls = 0
        let monitor = ClaudeCodeActivityMonitor(
            projectsDirectory: fixtureDirectory,
            clock: { [weak self] in self?.currentDate ?? Date() },
            processRunner: { _, _ in
                processCalls += 1
                if shouldThrow { throw FixtureError.processFailed }
                return ClaudeProcessResult(
                    standardOutput: Data(processOutput.utf8),
                    terminationStatus: terminationStatus
                )
            }
        )

        let present = monitor.activityStatus()
        XCTAssertTrue(present.processRunning)
        XCTAssertEqual(present.ttys, ["ttys002"])
        XCTAssertEqual(present.observation, .active)
        XCTAssertEqual(processCalls, 1)

        currentDate = currentDate.addingTimeInterval(1.1)
        shouldThrow = true
        let throwAfterPresent = monitor.activityStatus()
        XCTAssertTrue(throwAfterPresent.processRunning)
        XCTAssertEqual(throwAfterPresent.ttys, ["ttys002"])
        XCTAssertEqual(throwAfterPresent.observation, .active)
        XCTAssertEqual(processCalls, 2)

        currentDate = currentDate.addingTimeInterval(0.5)
        XCTAssertTrue(monitor.activityStatus().processRunning)
        XCTAssertEqual(processCalls, 2)

        currentDate = currentDate.addingTimeInterval(0.6)
        shouldThrow = false
        terminationStatus = 1
        let nonZeroAfterPresent = monitor.activityStatus()
        XCTAssertTrue(nonZeroAfterPresent.processRunning)
        XCTAssertEqual(nonZeroAfterPresent.ttys, ["ttys002"])
        XCTAssertNotEqual(nonZeroAfterPresent.observation, .hardTerminal)
        XCTAssertEqual(processCalls, 3)

        currentDate = currentDate.addingTimeInterval(1.1)
        terminationStatus = 0
        processOutput = "101 1 ?? /usr/bin/python worker.py"
        let recoveredAbsent = monitor.activityStatus()
        XCTAssertFalse(recoveredAbsent.processRunning)
        XCTAssertEqual(recoveredAbsent.observation, .hardTerminal)
        XCTAssertEqual(recoveredAbsent.ttys, [])
        XCTAssertEqual(processCalls, 4)
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

        let monitor = makeMonitor()
        XCTAssertFalse(monitor.status().taskRunning)
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        currentDate = currentDate.addingTimeInterval(1.0)
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.transcriptReadCount, 1)
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

    func testUnchangedTranscriptIdentityDoesNotReread() throws {
        _ = try writeSession([
            try assistantEvent(stopReason: "tool_use", contentTypes: [])
        ])
        let monitor = makeMonitor()

        let first = monitor.activityStatus()
        XCTAssertEqual(first.observation, .active)
        XCTAssertTrue(first.trueTurnEvidence)
        XCTAssertEqual(monitor.transcriptReadCount, 1)

        currentDate = currentDate.addingTimeInterval(1.0)
        let second = monitor.activityStatus()
        XCTAssertEqual(second.observation, .active)
        XCTAssertTrue(second.trueTurnEvidence)
        XCTAssertEqual(monitor.transcriptReadCount, 1)
    }

    func testTranscriptSizeOrMtimeChangeReparses() throws {
        let sessionURL = try writeSession([
            try assistantEvent(stopReason: "tool_use", contentTypes: [])
        ])
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        XCTAssertEqual(monitor.transcriptReadCount, 1)

        currentDate = currentDate.addingTimeInterval(1.0)
        try FileManager.default.setAttributes(
            [.modificationDate: currentDate],
            ofItemAtPath: sessionURL.path
        )
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        XCTAssertEqual(monitor.transcriptReadCount, 2)

        currentDate = currentDate.addingTimeInterval(1.0)
        _ = try writeSession([
            try assistantEvent(stopReason: "end_turn", contentTypes: [])
        ], modifiedAt: currentDate)
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.transcriptReadCount, 3)
    }

    func testRecentWriteExpiryDropsToAmbiguousIdleWithoutReread() throws {
        _ = try writeSession(
            [try assistantEvent(stopReason: nil, contentTypes: [])],
            modifiedAt: currentDate
        )
        let monitor = makeMonitor()
        let first = monitor.activityStatus()
        XCTAssertEqual(first.observation, .active)
        XCTAssertFalse(first.trueTurnEvidence)
        XCTAssertEqual(monitor.transcriptReadCount, 1)

        currentDate = currentDate.addingTimeInterval(16)
        let expired = monitor.activityStatus()
        XCTAssertEqual(expired.observation, .ambiguousIdle)
        XCTAssertFalse(expired.trueTurnEvidence)
        XCTAssertEqual(monitor.transcriptReadCount, 1)
    }

    func testContentDeterminedTranscriptsDoNotReparseAfterFormerTTL() throws {
        let thinkingURL = try writeSession(
            [try assistantEvent(stopReason: nil, contentTypes: ["thinking"])],
            filename: "thinking.jsonl"
        )
        let thinkingMonitor = makeMonitor()
        XCTAssertEqual(thinkingMonitor.activityStatus().observation, .active)
        XCTAssertTrue(thinkingMonitor.activityStatus().trueTurnEvidence)
        currentDate = currentDate.addingTimeInterval(1.0)
        XCTAssertEqual(thinkingMonitor.activityStatus().observation, .active)
        XCTAssertEqual(thinkingMonitor.transcriptReadCount, 1)

        currentDate = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try writeSession(
            [try assistantEvent(stopReason: "end_turn", contentTypes: [])],
            filename: "terminal.jsonl",
            modifiedAt: currentDate.addingTimeInterval(1)
        )
        let terminalMonitor = makeMonitor()
        XCTAssertEqual(terminalMonitor.activityStatus().observation, .hardTerminal)
        currentDate = currentDate.addingTimeInterval(2.0)
        XCTAssertEqual(terminalMonitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(terminalMonitor.transcriptReadCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: thinkingURL.path))
    }

    func testTranscriptTailKeeps192KBAndDropsPartialFirstLine() throws {
        let tailSize = 192 * 1024
        let hiddenTerminal = try assistantEvent(stopReason: "end_turn", contentTypes: []) + "\n"
        let visibleToolUse = try assistantEvent(stopReason: "tool_use", contentTypes: []) + "\n"
        let suffixPadding = String(repeating: "y\n", count: 75 * 1024)
        let distanceFromEnd = visibleToolUse.utf8.count + suffixPadding.utf8.count
        XCTAssertGreaterThan(distanceFromEnd, 96 * 1024)
        XCTAssertLessThan(distanceFromEnd, tailSize)

        var prefix = hiddenTerminal
        let paddingLine = String(repeating: "x", count: 1023) + "\n"
        while prefix.utf8.count + distanceFromEnd <= tailSize {
            prefix += paddingLine
        }
        let largeBody = prefix + visibleToolUse + suffixPadding
        XCTAssertGreaterThan(largeBody.utf8.count, tailSize)
        _ = try writeRawSession(largeBody, filename: "large-tail.jsonl")
        let tailMonitor = makeMonitor()
        let tailStatus = tailMonitor.activityStatus()
        XCTAssertEqual(tailStatus.observation, .active)
        XCTAssertTrue(tailStatus.trueTurnEvidence)

        let droppedTerminal = try assistantEvent(stopReason: "end_turn", contentTypes: []) + "\n"
        var droppedTail = Data(droppedTerminal.utf8)
        droppedTail.append(Data(repeating: UInt8(ascii: "\n"), count: tailSize - droppedTail.count))
        XCTAssertEqual(droppedTail.count, tailSize)
        var splitBody = Data("HEAD\n".utf8)
        splitBody.append(droppedTail)
        _ = try writeRawSession(splitBody, filename: "partial-first-line.jsonl", modifiedAt: currentDate.addingTimeInterval(1))
        currentDate = currentDate.addingTimeInterval(3)
        let splitMonitor = makeMonitor()
        let splitStatus = splitMonitor.activityStatus()
        XCTAssertEqual(splitStatus.observation, .active)
        XCTAssertFalse(splitStatus.trueTurnEvidence)
        XCTAssertNotEqual(splitStatus.observation, .hardTerminal)
    }

    func testTranscriptReadFailureRetriesInsteadOfCachingIdle() throws {
        let projectDirectory = fixtureDirectory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let sessionURL = projectDirectory.appendingPathComponent("damaged.jsonl")
        try Data([0x7B, 0xFF, 0x0A]).write(to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: currentDate],
            ofItemAtPath: sessionURL.path
        )

        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .ambiguousIdle)
        XCTAssertEqual(monitor.transcriptReadCount, 1)
        currentDate = currentDate.addingTimeInterval(0.5)
        XCTAssertEqual(monitor.activityStatus().observation, .ambiguousIdle)
        XCTAssertEqual(monitor.transcriptReadCount, 1)

        currentDate = currentDate.addingTimeInterval(0.6)
        XCTAssertEqual(monitor.activityStatus().observation, .ambiguousIdle)
        XCTAssertEqual(monitor.transcriptReadCount, 2)
    }

    func testLatestSessionHotPathSkipsTreeScanWhileMtimeIsFresh() throws {
        let activeURL = try writeSession(
            [try assistantEvent(stopReason: "tool_use", contentTypes: [])],
            filename: "active.jsonl"
        )
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        XCTAssertEqual(monitor.sessionScanCount, 1)

        currentDate = currentDate.addingTimeInterval(0.5)
        try FileManager.default.setAttributes(
            [.modificationDate: currentDate],
            ofItemAtPath: activeURL.path
        )
        _ = try writeSession(
            [try assistantEvent(stopReason: "end_turn", contentTypes: [])],
            filename: "newer.jsonl",
            modifiedAt: currentDate.addingTimeInterval(1)
        )
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        XCTAssertEqual(monitor.sessionScanCount, 1)

        currentDate = currentDate.addingTimeInterval(2.0)
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.sessionScanCount, 2)
    }

    func testDeletedLatestSessionForcesRescan() throws {
        let latest = try writeSession(
            [try assistantEvent(stopReason: "tool_use", contentTypes: [])],
            filename: "latest.jsonl",
            modifiedAt: currentDate
        )
        _ = try writeSession(
            [try assistantEvent(stopReason: "end_turn", contentTypes: [])],
            filename: "older.jsonl",
            modifiedAt: currentDate.addingTimeInterval(-1)
        )
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.activityStatus().observation, .active)
        XCTAssertEqual(monitor.sessionScanCount, 1)

        try FileManager.default.removeItem(at: latest)
        currentDate = currentDate.addingTimeInterval(0.2)
        XCTAssertEqual(monitor.activityStatus().observation, .hardTerminal)
        XCTAssertEqual(monitor.sessionScanCount, 2)
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

    @discardableResult
    private func writeRawSession(
        _ text: String,
        filename: String,
        modifiedAt: Date? = nil
    ) throws -> URL {
        try writeRawSession(Data(text.utf8), filename: filename, modifiedAt: modifiedAt)
    }

    @discardableResult
    private func writeRawSession(
        _ data: Data,
        filename: String,
        modifiedAt: Date? = nil
    ) throws -> URL {
        let projectDirectory = fixtureDirectory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let sessionURL = projectDirectory.appendingPathComponent(filename)
        try data.write(to: sessionURL)
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
