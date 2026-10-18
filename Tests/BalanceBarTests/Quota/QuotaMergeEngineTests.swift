import Foundation
import XCTest
@testable import BalanceBar

final class QuotaMergeEngineTests: XCTestCase {
    private final class FakeScheduler: FetchScheduling {
        var reasons: [FetchRequestReason] = []
        func requestFetch(reason: FetchRequestReason) { reasons.append(reason) }
    }

    private final class FakeSink: QuotaNotificationSink {
        var events: [QuotaNotificationEvent] = []
        func publish(_ event: QuotaNotificationEvent) { events.append(event) }
    }

    private final class MemoryStore: QuotaMergeStateStoring {
        var saved: QuotaMergeState?
        func load() -> QuotaMergeState? { saved }
        func save(_ state: QuotaMergeState) { saved = state }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var scheduler = FakeScheduler()
    private var sink = FakeSink()

    private func makeEngine(store: QuotaMergeStateStoring? = nil) -> QuotaMergeEngine {
        QuotaMergeEngine(scheduler: scheduler, notifications: sink, store: store, now: { [unowned self] in clock })
    }

    private func obs(
        _ used: Double,
        resetsIn: TimeInterval? = 3_600,
        at offset: TimeInterval = 0,
        trust: QuotaTrust = .a,
        account: String = "acct-1",
        epoch: UInt64 = 0
    ) -> QuotaObservation {
        obs(.fiveHour, used, resetsIn: resetsIn, at: offset, trust: trust, account: account, epoch: epoch)
    }

    private func obs(
        _ window: QuotaWindowKind,
        _ used: Double,
        resetsIn: TimeInterval? = 3_600,
        at offset: TimeInterval = 0,
        trust: QuotaTrust = .a,
        account: String = "acct-1",
        epoch: UInt64 = 0
    ) -> QuotaObservation {
        QuotaObservation(
            window: window,
            usedPercentage: used,
            resetsAt: resetsIn.map { t0.addingTimeInterval($0) },
            observedAt: t0.addingTimeInterval(offset),
            receivedAt: t0.addingTimeInterval(offset),
            source: trust == .a ? "api" : "claude-hud",
            trust: trust,
            accountID: account,
            epoch: AccountEpoch(epoch)
        )!
    }

    // MARK: - Grade B admission (table driven)

    func testGradeBAdmissionRules() {
        struct Case { let name: String; let seedA: Bool; let bUsed: Double; let bResetsIn: TimeInterval?; let expected: Double? }
        let cases = [
            Case(name: "no grade-A yet", seedA: false, bUsed: 50, bResetsIn: 3_600, expected: nil),
            Case(name: "higher than A", seedA: true, bUsed: 45, bResetsIn: 3_600, expected: 45),
            Case(name: "within tolerance below A", seedA: true, bUsed: 38.5, bResetsIn: 3_600, expected: 38.5),
            Case(name: "below tolerance", seedA: true, bUsed: 37, bResetsIn: 3_600, expected: 40),
            Case(name: "different cycle", seedA: true, bUsed: 45, bResetsIn: 9_000, expected: 40),
            Case(name: "missing reset time", seedA: true, bUsed: 45, bResetsIn: nil, expected: 40),
        ]
        for c in cases {
            scheduler = FakeScheduler()
            let engine = makeEngine()
            if c.seedA { engine.merge(obs(40)) }
            let model = engine.merge(obs(c.bUsed, resetsIn: c.bResetsIn, at: 10, trust: .b))
            XCTAssertEqual(model.window(for: .fiveHour)?.usedPercentage, c.expected, c.name)
        }
    }

    // MARK: - Ordering, per-window independence, missing windows

    func testOlderObservationDoesNotOverwriteNewer() {
        let engine = makeEngine()
        engine.merge(obs(40, at: 20))
        let model = engine.merge(obs(30, at: 10))
        XCTAssertEqual(model.window(for: .fiveHour)?.usedPercentage, 40)
    }

    func testWindowsMergeIndependentlyAndMissingWindowKeepsLastValue() {
        let engine = makeEngine()
        engine.merge(obs(.fiveHour, 40))
        engine.merge(obs(.sevenDay, 10, resetsIn: 86_400))
        let model = engine.merge(obs(.fiveHour, 55, at: 30))
        XCTAssertEqual(model.window(for: .fiveHour)?.usedPercentage, 55)
        XCTAssertEqual(model.window(for: .sevenDay)?.usedPercentage, 10)
        XCTAssertEqual(model.window(for: .sevenDay)?.state, .inProgress)
    }

    func testWindowStates() {
        struct Case { let used: Double; let resetsIn: TimeInterval?; let expected: WindowState }
        let cases = [
            Case(used: 0, resetsIn: nil, expected: .notStarted),
            Case(used: 0, resetsIn: 3_600, expected: .inProgress),
            Case(used: 12, resetsIn: nil, expected: .inProgress),
        ]
        for c in cases {
            let model = makeEngine().merge(obs(c.used, resetsIn: c.resetsIn))
            XCTAssertEqual(model.window(for: .fiveHour)?.state, c.expected, "\(c)")
        }
        XCTAssertEqual(makeEngine().displayModel.window(for: .sevenDay)?.state, .noData)
        XCTAssertEqual(makeEngine().displayModel.state, .noData)
    }

    // MARK: - Reset confirmation state machine

    func testResetConfirmationFullPath() {
        let engine = makeEngine()
        engine.merge(obs(80, resetsIn: 3_600))
        XCTAssertTrue(scheduler.reasons.isEmpty)

        clock = t0.addingTimeInterval(3_601)
        var model = engine.refresh()
        XCTAssertEqual(model.window(for: .fiveHour)?.state, .resetPendingConfirmation)
        XCTAssertEqual(model.state, .resetPendingConfirmation)
        XCTAssertEqual(scheduler.reasons, [.resetConfirmation])
        engine.refresh()
        XCTAssertEqual(scheduler.reasons.count, 1, "confirmation requested once per reset")

        // Old-cycle and grade-B readings do not confirm.
        model = engine.merge(obs(80, resetsIn: 3_600, at: 3_602))
        XCTAssertEqual(model.window(for: .fiveHour)?.state, .resetPendingConfirmation)
        model = engine.merge(obs(2, resetsIn: 3_600 + 18_000, at: 3_603, trust: .b))
        XCTAssertEqual(model.window(for: .fiveHour)?.state, .resetPendingConfirmation)
        XCTAssertTrue(sink.events.isEmpty)

        model = engine.merge(obs(3, resetsIn: 3_600 + 18_000, at: 3_604))
        XCTAssertEqual(model.window(for: .fiveHour)?.state, .inProgress)
        XCTAssertEqual(model.window(for: .fiveHour)?.usedPercentage, 3)
        XCTAssertEqual(sink.events, [.resetConfirmed(window: .fiveHour)])
    }

    func testNotStartedReadingConfirmsReset() {
        let engine = makeEngine()
        engine.merge(obs(80, resetsIn: 60))
        clock = t0.addingTimeInterval(61)
        let model = engine.merge(obs(0, resetsIn: nil, at: 62))
        XCTAssertEqual(model.window(for: .fiveHour)?.state, .notStarted)
        XCTAssertEqual(sink.events, [.resetConfirmed(window: .fiveHour)])
    }

    // MARK: - Account switching

    func testEpochChangeClearsOldAccountAndGradeB() {
        let engine = makeEngine()
        engine.merge(obs(40))
        engine.merge(obs(45, at: 5, trust: .b))
        var model = engine.merge(obs(.sevenDay, 5, resetsIn: 86_400, trust: .b, account: "acct-2", epoch: 1))
        XCTAssertNil(model.window(for: .fiveHour)?.usedPercentage)
        XCTAssertNil(model.window(for: .sevenDay)?.usedPercentage, "grade-B isolated after switch")

        model = engine.merge(obs(41, at: 6, account: "acct-1", epoch: 0))
        XCTAssertNil(model.window(for: .fiveHour)?.usedPercentage, "stale epoch rejected")

        model = engine.accountDidChange(epoch: AccountEpoch(2), accountID: "acct-3")
        XCTAssertEqual(model.state, .noData)
        XCTAssertEqual(engine.currentState.accountID, "acct-3")
    }

    func testDifferentAccountInSameEpochIsRejected() {
        let engine = makeEngine()
        engine.merge(obs(40))
        let model = engine.merge(obs(90, at: 5, account: "acct-2"))
        XCTAssertEqual(model.window(for: .fiveHour)?.usedPercentage, 40)
    }

    // MARK: - Persistence

    func testPersistenceRoundTripOutputsCachedValueFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("quota-merge.json")
        let store = QuotaMergeFileStore(url: url)
        let engine = makeEngine(store: store)
        engine.merge(obs(40))
        engine.merge(obs(.sevenDay, 10, resetsIn: 86_400))
        store.flush()

        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.lowercased().contains("token"))

        let restored = makeEngine(store: QuotaMergeFileStore(url: url))
        XCTAssertEqual(restored.displayModel, engine.displayModel)
        XCTAssertEqual(restored.displayModel.window(for: .fiveHour)?.usedPercentage, 40)
        XCTAssertEqual(restored.currentState, engine.currentState)
    }

    func testCorruptStoreStartsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("quota-merge.json")
        try Data("{".utf8).write(to: url)
        XCTAssertEqual(makeEngine(store: QuotaMergeFileStore(url: url)).displayModel.state, .noData)
    }

    func testPendingStateSurvivesRestart() {
        let store = MemoryStore()
        let engine = makeEngine(store: store)
        engine.merge(obs(80, resetsIn: 60))
        clock = t0.addingTimeInterval(61)
        engine.refresh()
        XCTAssertEqual(makeEngine(store: store).displayModel.window(for: .fiveHour)?.state, .resetPendingConfirmation)
    }

    // MARK: - Review regressions

    func testStaleAccountChangeIsIgnored() {
        let engine = makeEngine()
        engine.accountDidChange(epoch: AccountEpoch(2), accountID: "acct-b")
        engine.merge(obs(40, account: "acct-b", epoch: 2))
        var model = engine.accountDidChange(epoch: AccountEpoch(1), accountID: "acct-a")
        XCTAssertEqual(model.window(for: .fiveHour)?.usedPercentage, 40)
        XCTAssertEqual(engine.currentState.accountID, "acct-b")
        XCTAssertEqual(engine.currentState.epoch, AccountEpoch(2))
        model = engine.merge(obs(42, at: 5, account: "acct-b", epoch: 2))
        XCTAssertEqual(model.window(for: .fiveHour)?.usedPercentage, 42)
    }

    func testEpochSwitchPersistsEvenWhenObservationRejected() {
        let store = MemoryStore()
        let engine = makeEngine(store: store)
        engine.merge(obs(40))
        let model = engine.merge(obs(45, at: 5, trust: .b, account: "acct-b", epoch: 1))
        XCTAssertNil(model.window(for: .fiveHour)?.usedPercentage)

        let restarted = makeEngine(store: store)
        XCTAssertEqual(restarted.displayModel.state, .noData)
        XCTAssertEqual(restarted.currentState.accountID, "acct-b")
        XCTAssertEqual(restarted.currentState.epoch, AccountEpoch(1))
    }

    func testStaleObservationDuringPendingDoesNotConfirm() {
        let engine = makeEngine()
        engine.merge(obs(80, resetsIn: 3_600, at: 100))
        clock = t0.addingTimeInterval(3_601)
        engine.refresh()

        var model = engine.merge(obs(0, resetsIn: nil, at: 50))
        XCTAssertEqual(model.window(for: .fiveHour)?.state, .resetPendingConfirmation)
        XCTAssertEqual(model.window(for: .fiveHour)?.usedPercentage, 80)
        model = engine.merge(obs(0, resetsIn: 3_600 + 18_000, at: 3_000))
        XCTAssertEqual(model.window(for: .fiveHour)?.state, .resetPendingConfirmation)
        XCTAssertTrue(sink.events.isEmpty)

        model = engine.merge(obs(1, resetsIn: 3_600 + 18_000, at: 3_602))
        XCTAssertEqual(model.window(for: .fiveHour)?.state, .inProgress)
        XCTAssertEqual(sink.events, [.resetConfirmed(window: .fiveHour)])
    }

    func testGradeBZeroDoesNotProduceNotStarted() {
        let engine = makeEngine()
        engine.merge(obs(1, resetsIn: nil))
        let model = engine.merge(obs(0, resetsIn: nil, at: 5, trust: .b))
        XCTAssertEqual(model.window(for: .fiveHour)?.usedPercentage, 0)
        XCTAssertEqual(model.window(for: .fiveHour)?.state, .inProgress)
    }
}
