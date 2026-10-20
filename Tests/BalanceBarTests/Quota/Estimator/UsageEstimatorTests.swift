import XCTest
@testable import BalanceBar

private struct FakeAccounts: AccountTimelineProviding {
    var timeline: [AccountTimelineEntry]
    func timelineEntry(at date: Date) -> AccountTimelineEntry? { timeline.last { $0.switchedAt <= date } }
}

final class UsageEstimatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageEstimatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func identity(_ id: String) -> AccountIdentity {
        AccountIdentity(stableID: id, idSource: .accountUUID)
    }

    private func entry(_ id: String?, epoch: UInt64, at date: Date) -> AccountTimelineEntry {
        AccountTimelineEntry(identity: id.map(identity), epoch: AccountEpoch(rawValue: epoch), switchedAt: date)
    }

    private func line(
        uuid: String, request: String? = nil, at date: Date, model: String = "claude-sonnet-4",
        input: Int = 100, output: Int = 100, cacheCreate: Int = 0, cacheRead: Int = 0,
        session: String = "s1", sidechain: Bool = false
    ) -> Data {
        let stamp = ISO8601DateFormatter().string(from: date)
        var object: [String: Any] = [
            "type": "assistant", "uuid": uuid, "timestamp": stamp, "sessionId": session, "isSidechain": sidechain,
            "message": ["model": model, "usage": [
                "input_tokens": input, "output_tokens": output,
                "cache_creation_input_tokens": cacheCreate, "cache_read_input_tokens": cacheRead]],
        ]
        if let request { object["requestId"] = request }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func makeEstimator(
        accounts: [AccountTimelineEntry]? = nil, officialFrom: Date? = nil, log: InMemoryShadowLog = InMemoryShadowLog(),
        configuration: EstimatorConfiguration = EstimatorConfiguration()
    ) -> (UsageEstimator, InMemoryShadowLog) {
        let providers = ProviderTimeline()
        providers.record(officialDirect: true, at: officialFrom ?? t0.addingTimeInterval(-10))
        let attributor = UsageAttributor(
            accounts: FakeAccounts(timeline: accounts ?? [entry("A", epoch: 1, at: t0.addingTimeInterval(-10))]),
            providers: providers)
        return (UsageEstimator(configuration: configuration, attributor: attributor, log: log), log)
    }

    // MARK: Parsing

    func testParserReadsAssistantUsageAndIgnoresOtherLines() {
        let record = TranscriptUsageParser.parse(line(uuid: "u1", request: "r1", at: t0, cacheRead: 7))
        XCTAssertEqual(record?.requestID, "r1")
        XCTAssertEqual(record?.cacheReadTokens, 7)
        XCTAssertNil(TranscriptUsageParser.parse(Data(#"{"type":"user","uuid":"x"}"#.utf8)))
        XCTAssertNil(TranscriptUsageParser.parse(Data("not json".utf8)))
    }

    // MARK: Deduplication

    func testDuplicateUUIDAndRequestAreCountedOnce() {
        let (estimator, _) = makeEstimator()
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 10, resetsAt: nil, at: t0)
        let at = t0.addingTimeInterval(5)
        let counted = estimator.ingest(lines: [
            line(uuid: "u1", request: "r1", at: at),
            line(uuid: "u1", request: "r1", at: at),      // same message
            line(uuid: "u2", request: "r1", at: at),      // same request, new block
            line(uuid: "u3", request: "r2", at: at),
        ])
        XCTAssertEqual(counted, 2)
        XCTAssertEqual(estimator.ingest(lines: [line(uuid: "u3", request: "r2", at: at)]), 0)
    }

    func testLaterRecordOfSameRequestReplacesEarlierUsage() {
        let (estimator, _) = makeEstimator()
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 10, resetsAt: nil, at: t0)
        let at = t0.addingTimeInterval(5)
        XCTAssertEqual(estimator.ingest(lines: [line(uuid: "u1", request: "r1", at: at, input: 0, output: 2)]), 1)
        let early = estimator.estimate(accountID: "A", window: .fiveHour)!.percent
        // Same request later reports its final usage (new block uuid).
        XCTAssertEqual(estimator.ingest(lines: [line(uuid: "u2", request: "r1", at: at, input: 0, output: 500)]), 0)
        let final = estimator.estimate(accountID: "A", window: .fiveHour)!.percent
        XCTAssertGreaterThan(final, early)
        // Expected: exactly one request of 500 output tokens counted, not 502 and not 2.
        let (reference, _) = makeEstimator()
        _ = reference.recordOfficial(accountID: "A", window: .fiveHour, percent: 10, resetsAt: nil, at: t0)
        reference.ingest(lines: [line(uuid: "x", request: "rx", at: at, input: 0, output: 500)])
        XCTAssertEqual(final, reference.estimate(accountID: "A", window: .fiveHour)!.percent, accuracy: 1e-9)
        // Repeating the final record changes nothing.
        estimator.ingest(lines: [line(uuid: "u2", request: "r1", at: at, input: 0, output: 500)])
        XCTAssertEqual(estimator.estimate(accountID: "A", window: .fiveHour)!.percent, final, accuracy: 1e-9)
    }

    func testSameRequestRepeatedAcrossOfficialAnchorIsNotCountedAgain() {
        let (estimator, _) = makeEstimator()
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 10, resetsAt: nil, at: t0)
        estimator.ingest(lines: [line(uuid: "u1", request: "r1", at: t0.addingTimeInterval(10), input: 100, output: 0)])
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 10, resetsAt: nil, at: t0.addingTimeInterval(60))
        // Same usage, later timestamp, after the new anchor.
        estimator.ingest(lines: [line(uuid: "u2", request: "r1", at: t0.addingTimeInterval(120), input: 100, output: 0)])
        XCTAssertEqual(estimator.estimate(accountID: "A", window: .fiveHour)?.percent, 10)
        // Growth of that request after the anchor counts only the growth (50 more input tokens).
        estimator.ingest(lines: [line(uuid: "u3", request: "r1", at: t0.addingTimeInterval(130), input: 150, output: 0)])
        let (reference, _) = makeEstimator()
        _ = reference.recordOfficial(accountID: "A", window: .fiveHour, percent: 10, resetsAt: nil, at: t0)
        reference.ingest(lines: [line(uuid: "x", request: "rx", at: t0.addingTimeInterval(10), input: 50, output: 0)])
        XCTAssertEqual(estimator.estimate(accountID: "A", window: .fiveHour)!.percent,
                       reference.estimate(accountID: "A", window: .fiveHour)!.percent, accuracy: 1e-9)
    }

    func testRequestGrowthAcrossResetDeadlineCountsInNewCycle() {
        let (estimator, _) = makeEstimator()
        let reset = t0.addingTimeInterval(1_800)
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 50, resetsAt: reset, at: t0)
        estimator.ingest(lines: [line(uuid: "u1", request: "r1", at: reset.addingTimeInterval(-60), input: 100_000, output: 0)])
        estimator.ingest(lines: [line(uuid: "u2", request: "r1", at: reset.addingTimeInterval(60), input: 150_000, output: 0)])
        let entry = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 1,
                                             resetsAt: reset.addingTimeInterval(18_000), at: reset.addingTimeInterval(300))
        let (reference, _) = makeEstimator()
        _ = reference.recordOfficial(accountID: "A", window: .fiveHour, percent: 50, resetsAt: reset, at: t0)
        reference.ingest(lines: [line(uuid: "x", request: "rx", at: reset.addingTimeInterval(60), input: 50_000, output: 0)])
        let expected = reference.recordOfficial(accountID: "A", window: .fiveHour, percent: 1,
                                                resetsAt: reset.addingTimeInterval(18_000), at: reset.addingTimeInterval(300))
        XCTAssertGreaterThan(entry!.estimatedPercent, 0)
        XCTAssertEqual(entry!.estimatedPercent, expected!.estimatedPercent, accuracy: 1e-9)
    }

    func testUsageBeforeResetDeadlineIsNotComparedWithNewCycle() {
        let (estimator, log) = makeEstimator()
        let reset = t0.addingTimeInterval(1_800)
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 50, resetsAt: reset, at: t0)
        estimator.ingest(lines: [line(uuid: "u1", request: "r1", at: t0.addingTimeInterval(600), input: 100_000, output: 0)])
        let result = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 0,
                                              resetsAt: reset.addingTimeInterval(18_000), at: reset.addingTimeInterval(600))
        XCTAssertEqual(result?.scenarios, [EstimatorScenario.resetBoundary])
        XCTAssertEqual(result?.estimatedPercent, 0)
        XCTAssertEqual(log.entries.count, 1)
        // Usage after the deadline does count toward the new cycle.
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 2,
                                     resetsAt: reset.addingTimeInterval(18_000), at: reset.addingTimeInterval(1_200))
        estimator.ingest(lines: [line(uuid: "u2", request: "r2", at: reset.addingTimeInterval(1_300), input: 100_000, output: 0)])
        XCTAssertGreaterThan(estimator.estimate(accountID: "A", window: .fiveHour)!.percent, 2)
    }

    func testResetWithUnknownDeadlineLogsNoComparison() {
        let (estimator, log) = makeEstimator()
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 50, resetsAt: nil, at: t0)
        estimator.ingest(lines: [line(uuid: "u1", request: "r1", at: t0.addingTimeInterval(10), input: 100_000)])
        XCTAssertNil(estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 0, resetsAt: nil, at: t0.addingTimeInterval(60)))
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(estimator.estimate(accountID: "A", window: .fiveHour)?.percent, 0)
    }

    // MARK: Attribution

    func testAttributionRequiresActiveAccountAndOfficialProvider() {
        let providers = ProviderTimeline()
        providers.record(officialDirect: true, at: t0)
        providers.record(officialDirect: false, at: t0.addingTimeInterval(100))
        providers.record(officialDirect: true, at: t0.addingTimeInterval(200))
        let accounts = FakeAccounts(timeline: [
            entry("A", epoch: 1, at: t0), entry("B", epoch: 2, at: t0.addingTimeInterval(150)),
        ])
        let attributor = UsageAttributor(accounts: accounts, providers: providers)
        func result(_ offset: TimeInterval) -> UsageAttributionResult {
            attributor.attribute(TranscriptUsageParser.parse(line(uuid: "u", at: t0.addingTimeInterval(offset)))!)
        }
        XCTAssertEqual(result(-5), .noAccount)
        XCTAssertEqual(result(50), .attributed(accountID: "A"))
        XCTAssertEqual(result(120), .providerNotOfficial)
        XCTAssertEqual(result(160), .providerNotOfficial)     // account B, but provider still third-party
        XCTAssertEqual(result(250), .attributed(accountID: "B"))
        XCTAssertTrue(attributor.switchOccurred(from: t0.addingTimeInterval(140), to: t0.addingTimeInterval(160)))
        XCTAssertFalse(attributor.switchOccurred(from: t0.addingTimeInterval(210), to: t0.addingTimeInterval(220)))
    }

    func testUnknownProviderHistoryIsNotAttributed() {
        let attributor = UsageAttributor(
            accounts: FakeAccounts(timeline: [entry("A", epoch: 1, at: t0)]), providers: ProviderTimeline())
        XCTAssertEqual(attributor.attribute(TranscriptUsageParser.parse(line(uuid: "u", at: t0.addingTimeInterval(1)))!),
                       .providerNotOfficial)
    }

    func testOtherAccountUsageDoesNotAffectEstimate() {
        let (estimator, _) = makeEstimator(accounts: [
            entry("A", epoch: 1, at: t0.addingTimeInterval(-10)), entry("B", epoch: 2, at: t0.addingTimeInterval(60))])
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 10, resetsAt: nil, at: t0)
        estimator.ingest(lines: [line(uuid: "u1", request: "r1", at: t0.addingTimeInterval(120), output: 50_000)])
        XCTAssertEqual(estimator.estimate(accountID: "A", window: .fiveHour)?.percent, 10)
    }

    // MARK: Weight fallback

    func testWeightFallbackModelThenFamilyThenPrior() {
        var model = UsageWeightModel()
        XCTAssertEqual(model.multiplier(for: "claude-opus-4").level, .prior)
        XCTAssertEqual(model.multiplier(for: "claude-opus-4").value, 5)
        for _ in 0..<3 { model.learn(ratio: 2, shares: ["claude-opus-4": 1]) }
        XCTAssertEqual(model.multiplier(for: "claude-opus-4").level, .model)
        XCTAssertGreaterThan(model.multiplier(for: "claude-opus-4").value, 5)
        // A sibling model of the same family falls back to the learned family scale.
        XCTAssertEqual(model.multiplier(for: "claude-opus-4-1").level, .family)
        XCTAssertGreaterThan(model.multiplier(for: "claude-opus-4-1").value, 5)
        // Unrelated family keeps its prior.
        XCTAssertEqual(model.multiplier(for: "claude-haiku-4").level, .prior)
        XCTAssertEqual(model.multiplier(for: "mystery").value, 1)
    }

    // MARK: Learning and shadow log

    func testEstimateConvergesAndShadowLogRecordsErrors() {
        let (estimator, log) = makeEstimator()
        var now = t0
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 0, resetsAt: nil, at: now)
        var official = 0.0
        for index in 0..<8 {
            now = now.addingTimeInterval(600)
            estimator.ingest(lines: [line(uuid: "u\(index)", request: "r\(index)", at: now.addingTimeInterval(-5),
                                          input: 10_000, output: 10_000)])
            official += 6
            estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: official, resetsAt: nil, at: now)
        }
        let errors = log.entries.map { abs($0.error) }
        XCTAssertEqual(errors.count, 8)
        XCTAssertLessThan(errors.last!, errors.first!)
        XCTAssertLessThan(errors.last!, 1.5)
        XCTAssertGreaterThan(estimator.estimate(accountID: "A", window: .fiveHour)!.confidence, 0)
    }

    func testScenariosAreTagged() {
        let (estimator, log) = makeEstimator()
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 5, resetsAt: t0.addingTimeInterval(9_000), at: t0)
        let at = t0.addingTimeInterval(30)
        estimator.ingest(lines: [
            line(uuid: "u1", request: "r1", at: at, model: "claude-opus-4", input: 10, output: 10, cacheRead: 5_000),
            line(uuid: "u2", request: "r2", at: at, model: "claude-haiku-4", session: "s2", sidechain: true),
        ])
        let first = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 7,
                                             resetsAt: t0.addingTimeInterval(9_000), at: t0.addingTimeInterval(60))
        XCTAssertEqual(Set(first?.scenarios ?? []), [EstimatorScenario.multiModel, EstimatorScenario.cacheHeavy, EstimatorScenario.multiAgent])

        let reset = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 1,
                                             resetsAt: t0.addingTimeInterval(30_000), at: t0.addingTimeInterval(120))
        XCTAssertEqual(reset?.scenarios, [EstimatorScenario.resetBoundary])
        XCTAssertEqual(reset?.anchorPercent, 0)
        XCTAssertEqual(log.entries.count, 2)
    }

    func testAccountSwitchScenario() {
        let (estimator, _) = makeEstimator(accounts: [
            entry("A", epoch: 1, at: t0.addingTimeInterval(-10)), entry("B", epoch: 2, at: t0.addingTimeInterval(30))])
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 5, resetsAt: nil, at: t0)
        let result = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 6, resetsAt: nil, at: t0.addingTimeInterval(60))
        XCTAssertEqual(result?.scenarios, [EstimatorScenario.accountSwitch])
    }

    // MARK: Report

    func testReportGroupsByScenarioAndRenders() {
        func make(_ error: Double, _ scenarios: [String]) -> ShadowEntry {
            ShadowEntry(at: t0, accountID: "A", window: "five_hour", officialPercent: 10, estimatedPercent: 10 + error,
                        anchorPercent: 5, recordCount: 1, confidence: 0.5, errorRange: 2, scenarios: scenarios, weightLevels: [])
        }
        let report = ShadowReport(entries: [
            make(1, [EstimatorScenario.baseline]), make(-3, [EstimatorScenario.baseline]),
            make(4, [EstimatorScenario.multiModel, EstimatorScenario.multiAgent]),
        ])
        let all = report.stats.first { $0.scenario == EstimatorScenario.all }!
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.meanAbsoluteError, 8.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(all.withinRangeShare, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(report.stats.first { $0.scenario == EstimatorScenario.baseline }?.count, 2)
        XCTAssertEqual(report.stats.first { $0.scenario == EstimatorScenario.multiAgent }?.bias, 4)
        XCTAssertNil(report.stats.first { $0.scenario == EstimatorScenario.resetBoundary })
        XCTAssertTrue(report.render().contains("multi_model"))
    }

    func testFileLogRoundTrip() throws {
        let url = root.appendingPathComponent("logs/shadow.jsonl")
        let writer = ShadowLogFileWriter(url: url)
        let (estimator, _) = makeEstimator(log: InMemoryShadowLog())
        _ = estimator
        let entry = ShadowEntry(at: t0, accountID: "A", window: "five_hour", officialPercent: 10, estimatedPercent: 11,
                                anchorPercent: 5, recordCount: 2, confidence: 0.4, errorRange: 2, scenarios: ["baseline"], weightLevels: ["prior"])
        writer.append(entry); writer.append(entry); writer.flush()
        XCTAssertEqual(try ShadowLogFileWriter.readEntries(from: url), [entry, entry])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: Incremental reading with concurrent writers

    func testConcurrentAgentWritesAreIngestedExactlyOnce() throws {
        let (estimator, _) = makeEstimator()
        _ = estimator.recordOfficial(accountID: "A", window: .fiveHour, percent: 0, resetsAt: nil, at: t0)
        let reader = IncrementalJSONLReader(deduplicationKey: TranscriptUsageParser.readerDeduplicationKey)
        let files = (0..<4).map { root.appendingPathComponent("agent\($0).jsonl") }
        files.forEach { FileManager.default.createFile(atPath: $0.path, contents: nil) }
        let perFile = 250
        let writers = DispatchGroup()
        for (index, file) in files.enumerated() {
            DispatchQueue.global().async(group: writers) {
                let handle = try! FileHandle(forWritingTo: file)
                for n in 0..<perFile {
                    var data = self.line(uuid: "a\(index)-\(n)", request: "r\(index)-\(n)",
                                         at: self.t0.addingTimeInterval(10), session: "s\(index)", sidechain: true)
                    data.append(0x0A)
                    try! handle.write(contentsOf: data)
                }
                try? handle.close()
            }
        }
        var total = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 20 {
            for file in files {
                let result = try reader.read(file)
                total += estimator.ingest(lines: result.lines)
            }
            if total == files.count * perFile { break }
            usleep(2_000)
        }
        writers.wait()
        for file in files { total += estimator.ingest(lines: try reader.read(file).lines) }
        XCTAssertEqual(total, files.count * perFile)
        XCTAssertGreaterThan(estimator.estimate(accountID: "A", window: .fiveHour)!.percent, 0)
        print("PERF concurrent ingest: \(total) records in \(Date().timeIntervalSince(start)) s")
    }
}
