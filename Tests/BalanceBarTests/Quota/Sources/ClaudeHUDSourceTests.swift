import XCTest
@testable import BalanceBar

final class ClaudeHUDSourceTests: XCTestCase {
    private var root: URL!
    private var hud: URL!
    private var transcripts: URL!
    private var export: URL!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private struct FakeAccount: AccountIdentityProviding {
        var accountIdentity: AccountIdentity? = AccountIdentity(stableID: "claude:acct", idSource: .accountUUID)
        var credentialVersion: CredentialVersion? = nil
        var accountEpoch = AccountEpoch(2)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeHUDTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        hud = root.appendingPathComponent("plugins/claude-hud", isDirectory: true)
        transcripts = root.appendingPathComponent("projects", isDirectory: true)
        export = root.appendingPathComponent("export/usage.json")
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSource(
        configuration: ClaudeHUDConfiguration = ClaudeHUDConfiguration(),
        environment: [String: String] = [:],
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_100) }
    ) -> ClaudeHUDSource {
        ClaudeHUDSource(
            hudDirectory: hud, transcriptsDirectory: transcripts, accountProvider: FakeAccount(),
            configuration: configuration, environment: environment, homeDirectory: root, now: now
        )
    }

    private func writeConfig(_ json: String) throws {
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: hud.appendingPathComponent("config.json"))
    }

    private func writeConfig(exportingTo path: URL?) throws {
        let display = path.map { "{\"externalUsageWritePath\":\"\($0.path)\"}" } ?? "{}"
        try writeConfig("{\"display\":\(display)}")
    }

    private func writeSnapshot(used: Double, to url: URL? = nil) throws {
        let url = url ?? export!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter().string(from: base)
        let reset = ISO8601DateFormatter().string(from: base.addingTimeInterval(3_600))
        try Data("{\"updated_at\":\"\(iso)\",\"five_hour\":{\"used_percentage\":\(used),\"resets_at\":\"\(reset)\"}}".utf8)
            .write(to: url)
    }

    private func scan(_ source: ClaudeHUDSource, configChanged: Bool = true) -> [QuotaObservation] {
        var result: [QuotaObservation] = []
        source.rescan(configChanged: configChanged) { result.append($0) }
        return result
    }

    // MARK: Discovery

    func testSnapshotBecomesGradeBObservationWithUnknownObservedAt() throws {
        try writeConfig(exportingTo: export)
        try writeSnapshot(used: 42)
        let source = makeSource()
        defer { source.stop() }
        let observations = scan(source)
        XCTAssertEqual(observations.count, 1)
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observation.source, "claude-hud")
        XCTAssertEqual(observation.trust, .b)
        XCTAssertNil(observation.observedAt)
        XCTAssertEqual(observation.receivedAt, Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertEqual(observation.usedPercentage, 42)
        XCTAssertEqual(source.diagnostics.status, .exporting(path: export.standardizedFileURL))
        XCTAssertEqual(source.diagnostics.health, .healthy)
    }

    func testSourceIsAddedModifiedAndRemovedWithConfig() throws {
        let source = makeSource()
        defer { source.stop() }
        XCTAssertTrue(scan(source).isEmpty)
        XCTAssertEqual(source.diagnostics.status, .notInstalled)

        try writeConfig(exportingTo: export)
        try writeSnapshot(used: 10)
        XCTAssertEqual(scan(source).map(\.usedPercentage), [10])

        let other = root.appendingPathComponent("other/usage.json")
        try writeSnapshot(used: 77, to: other)
        try writeConfig(exportingTo: other)
        XCTAssertEqual(scan(source).map(\.usedPercentage), [77])
        XCTAssertEqual(source.diagnostics.status, .exporting(path: other.standardizedFileURL))

        try writeConfig(exportingTo: nil)
        XCTAssertTrue(scan(source).isEmpty)
        XCTAssertEqual(source.diagnostics.status, .exportDisabled)

        try FileManager.default.removeItem(at: hud.appendingPathComponent("config.json"))
        XCTAssertTrue(scan(source).isEmpty)
        XCTAssertEqual(source.diagnostics.status, .notInstalled)
    }

    func testInstalledWithoutExportOnlyReportsDiagnosticsAndLeavesConfigUntouched() throws {
        try writeConfig(exportingTo: nil)
        let configURL = hud.appendingPathComponent("config.json")
        let before = try Data(contentsOf: configURL)
        let source = makeSource()
        defer { source.stop() }
        XCTAssertTrue(scan(source).isEmpty)
        XCTAssertEqual(source.diagnostics.status, .exportDisabled)
        XCTAssertEqual(source.diagnostics.configurationExample, ClaudeHUDSource.configurationExample)
        XCTAssertEqual(try Data(contentsOf: configURL), before)
    }

    func testInvalidConfigsAreUnusable() throws {
        for json in ["[]", "{\"display\":{\"externalUsageWritePath\":5}}",
                     "{\"display\":{\"externalUsageWritePath\":\"relative.json\"}}"] {
            try writeConfig(json)
            let source = makeSource()
            defer { source.stop() }
            _ = scan(source)
            guard case .configUnusable = source.diagnostics.status else {
                return XCTFail("expected configUnusable for \(json), got \(source.diagnostics.status)")
            }
        }
    }

    func testMalformedSnapshotIsDegradedWithoutObservation() throws {
        try writeConfig(exportingTo: export)
        try FileManager.default.createDirectory(at: export.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: export)
        let source = makeSource()
        defer { source.stop() }
        XCTAssertTrue(scan(source).isEmpty)
        // The half-write retry runs after 0.1 s; poll instead of assuming how long that takes.
        let deadline = Date().addingTimeInterval(5)
        func isDegraded() -> Bool { if case .degraded = source.diagnostics.health { return true }; return false }
        while !isDegraded(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(isDegraded(), "expected degraded")
    }

    func testLiveWatchersFollowConfigWithoutRestart() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        let source = ClaudeHUDSource(
            hudDirectory: hud, transcriptsDirectory: transcripts, accountProvider: FakeAccount(),
            ioConfiguration: QuotaIOConfiguration(watchCoalescingInterval: 0.05)
        )
        defer { source.stop() }
        let received = expectation(description: "observation after config appears")
        received.assertForOverFulfill = false
        source.start { observation in
            if observation.usedPercentage == 55 { received.fulfill() }
        }
        // The watcher start-up time is not fixed, so rewrite until the observation arrives.
        let deadline = Date().addingTimeInterval(8)
        var outcome: XCTWaiter.Result
        repeat {
            try writeSnapshot(used: 55)
            try writeConfig(exportingTo: export)
            outcome = XCTWaiter.wait(for: [received], timeout: 0.5)
        } while outcome != .completed && Date() < deadline
        XCTAssertEqual(outcome, .completed)
    }

    func testEnvironmentVariablesAndTildeInExportPathAreExpanded() throws {
        try writeConfig("{\"display\":{\"externalUsageWritePath\":\"${EXPORT_DIR}/usage.json\"}}")
        let source = makeSource(environment: ["EXPORT_DIR": root.appendingPathComponent("export").path])
        defer { source.stop() }
        _ = scan(source)
        XCTAssertEqual(source.diagnostics.status, .exporting(path: export.standardizedFileURL))

        XCTAssertEqual(
            ClaudeHUDSource.expandPath("~/a/${X}/${UNSET}", environment: ["X": "b"], homeDirectory: root),
            root.path + "/a/b/${UNSET}"
        )
        XCTAssertEqual(ClaudeHUDSource.expandPath("~", environment: [:], homeDirectory: root), root.path)

        try writeConfig("{\"display\":{\"externalUsageWritePath\":\"${UNSET}/usage.json\"}}")
        _ = scan(source)
        guard case .configUnusable = source.diagnostics.status else { return XCTFail("unset variable stays relative") }
    }

    func testStopFromObservationHandlerDoesNotDeadlock() throws {
        try writeConfig(exportingTo: export)
        try writeSnapshot(used: 5)
        let source = makeSource()
        var count = 0
        source.rescan(configChanged: true) { _ in
            count += 1
            source.stop()
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: Headless signal

    func testResetClearsPreviousActivityTimestamp() throws {
        try writeConfig(exportingTo: export)
        let source = makeSource()
        defer { source.stop() }
        _ = scan(source) // no snapshot yet: HUD never alive
        source.recordTranscriptActivitySync(at: base)
        source.recordTranscriptActivitySync(at: base.addingTimeInterval(10))
        XCTAssertEqual(source.headlessDuration, 10)
        source.resetHeadlessDuration()
        source.recordTranscriptActivitySync(at: base.addingTimeInterval(30))
        XCTAssertEqual(source.headlessDuration, 0)
        source.recordTranscriptActivitySync(at: base.addingTimeInterval(35))
        XCTAssertEqual(source.headlessDuration, 5)
    }

    func testReenablingExportDoesNotCountActivityFromWhileDisabled() throws {
        try writeConfig(exportingTo: export)
        let source = makeSource()
        defer { source.stop() }
        _ = scan(source)
        source.recordTranscriptActivitySync(at: base)
        try writeConfig(exportingTo: nil)
        _ = scan(source)
        source.recordTranscriptActivitySync(at: base.addingTimeInterval(20)) // export off
        try writeConfig(exportingTo: export)
        _ = scan(source)
        source.recordTranscriptActivitySync(at: base.addingTimeInterval(30))
        XCTAssertEqual(source.headlessDuration, 0)
        source.recordTranscriptActivitySync(at: base.addingTimeInterval(40))
        XCTAssertEqual(source.headlessDuration, 10)
    }

    func testHeadlessDurationAccumulatesOnlyWhileSnapshotIsStale() throws {
        try writeConfig(exportingTo: export)
        try writeSnapshot(used: 1)
        let source = makeSource(configuration: ClaudeHUDConfiguration(snapshotLiveness: 30, maximumActivityGap: 60))
        defer { source.stop() }
        _ = scan(source) // snapshot received at base + 100

        let t0 = base.addingTimeInterval(100)
        source.recordTranscriptActivitySync(at: t0)
        source.recordTranscriptActivitySync(at: t0.addingTimeInterval(10)) // HUD alive: not headless
        XCTAssertEqual(source.headlessDuration, 0)

        source.recordTranscriptActivitySync(at: t0.addingTimeInterval(50)) // snapshot 50s old: +40
        source.recordTranscriptActivitySync(at: t0.addingTimeInterval(60)) // +10
        XCTAssertEqual(source.headlessDuration, 50)

        source.recordTranscriptActivitySync(at: t0.addingTimeInterval(1_000)) // idle gap capped at 60
        XCTAssertEqual(source.headlessDuration, 110)

        source.resetHeadlessDuration()
        XCTAssertEqual(source.headlessDuration, 0)
    }

    func testHeadlessDurationIgnoredWithoutExport() throws {
        let source = makeSource()
        defer { source.stop() }
        _ = scan(source)
        source.recordTranscriptActivitySync(at: base)
        source.recordTranscriptActivitySync(at: base.addingTimeInterval(20))
        XCTAssertEqual(source.headlessDuration, 0)
    }
}
