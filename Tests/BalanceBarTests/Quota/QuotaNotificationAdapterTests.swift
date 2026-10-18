import Foundation
import XCTest
@testable import BalanceBar

final class QuotaNotificationAdapterTests: XCTestCase {
    private func model(
        fiveHourUsed: Double?,
        estimated: Bool = false,
        state: WindowState = .inProgress
    ) -> QuotaDisplayModel {
        QuotaDisplayModel(
            windows: [QuotaWindowDisplay(
                kind: .fiveHour,
                usedPercentage: fiveHourUsed,
                isEstimated: estimated,
                state: state,
                hoverTextKey: "test"
            )],
            isEstimated: estimated,
            state: state,
            hoverTextKey: "test"
        )
    }

    private func harness() -> (QuotaNotificationAdapter, FakeBalanceNotificationClient) {
        let client = FakeBalanceNotificationClient(status: .authorized, requestResult: true)
        let suite = "QuotaNotificationAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let coordinator = BalanceNotificationCoordinator(defaults: defaults, client: client)
        coordinator.setGlobalEnabled(true)
        coordinator.setAgentEnabled(true, agent: .claude)
        coordinator.setProviderEnabled(true, agent: .claude, providerID: "claude-official")
        // Recovery is an existing per-rule switch (off by default); enable it
        // so the tests prove the adapter, not the switch, suppresses it.
        coordinator.updateRule(
            key: BalanceNotificationResourceKey(agent: .claude, providerID: "claude-official", resourceID: "five-hour"),
            kind: .quotaPercent,
            unit: "%"
        ) { $0.recoveryEnabled = true }
        let adapter = QuotaNotificationAdapter(processor: coordinator, providerID: "claude-official")
        return (adapter, client)
    }

    func testOfficialValueCrossingEightyAndNinetyFiveNotifiesOnceEach() {
        let (adapter, client) = harness()
        adapter.update(model(fiveHourUsed: 50), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 81), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 85), accountScope: "acct")
        XCTAssertEqual(client.deliveries.count, 1)
        adapter.update(model(fiveHourUsed: 96), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 97), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 96), accountScope: "acct")
        XCTAssertEqual(client.deliveries.count, 2)
    }

    func testEstimatedValueCrossingThresholdDoesNotNotify() {
        let (adapter, client) = harness()
        adapter.update(model(fiveHourUsed: 50), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 90, estimated: true), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 99, estimated: true), accountScope: "acct")
        XCTAssertTrue(client.deliveries.isEmpty)
    }

    func testPredictedResetWithoutConfirmationDoesNotSendRecovery() {
        let (adapter, client) = harness()
        adapter.update(model(fiveHourUsed: 50), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 90), accountScope: "acct")
        XCTAssertEqual(client.deliveries.count, 1)

        adapter.update(model(fiveHourUsed: 0, estimated: true, state: .resetPendingConfirmation), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 3), accountScope: "acct")
        XCTAssertEqual(client.deliveries.count, 1)

        adapter.publish(.resetConfirmed(window: .fiveHour))
        XCTAssertEqual(client.deliveries.count, 2)
        XCTAssertEqual(
            client.deliveries.last?.title,
            tr("notifications.recovered_title", arguments: [BalanceNotificationAgent.claude.title])
        )
    }

    func testConfirmationBeforeValueReleasesNextValueAndRearmsCycle() {
        let (adapter, client) = harness()
        adapter.update(model(fiveHourUsed: 50), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 90), accountScope: "acct")
        adapter.publish(.resetConfirmed(window: .fiveHour))
        XCTAssertEqual(client.deliveries.count, 1)
        adapter.update(model(fiveHourUsed: 2), accountScope: "acct")
        XCTAssertEqual(client.deliveries.count, 2)

        // The confirmation is consumed; a second unconfirmed rise is held.
        adapter.update(model(fiveHourUsed: 90), accountScope: "acct")
        XCTAssertEqual(client.deliveries.count, 3)
        adapter.update(model(fiveHourUsed: 1), accountScope: "acct")
        XCTAssertEqual(client.deliveries.count, 3)
    }

    func testDuplicateResetConfirmationDoesNotRepeatRecovery() {
        let (adapter, client) = harness()
        adapter.update(model(fiveHourUsed: 50), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 90), accountScope: "acct")
        adapter.update(model(fiveHourUsed: 1), accountScope: "acct")
        adapter.publish(.resetConfirmed(window: .fiveHour))
        adapter.publish(.resetConfirmed(window: .fiveHour))
        adapter.update(model(fiveHourUsed: 1), accountScope: "acct")
        XCTAssertEqual(client.deliveries.count, 2)
    }

    func testConcurrentResetCannotDeliverStaleSnapshotAfterNewerOne() {
        let processor = BlockingSnapshotProcessor(blockingRemaining: 10)
        let adapter = QuotaNotificationAdapter(processor: processor, providerID: "claude-official")
        adapter.update(model(fiveHourUsed: 50), accountScope: "acct")

        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            adapter.update(self.model(fiveHourUsed: 90), accountScope: "acct")
        }
        XCTAssertEqual(processor.entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async(group: group) {
            adapter.publish(.resetConfirmed(window: .fiveHour))
            adapter.update(self.model(fiveHourUsed: 2), accountScope: "acct")
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(processor.recorded, [50, 10])

        processor.gate.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(processor.recorded, [50, 10, 98])
    }
}

/// Records each snapshot's 5h remaining value; blocks inside `process` on
/// one value so the test can interleave a second caller.
private final class BlockingSnapshotProcessor: QuotaNotificationSnapshotProcessing {
    let entered = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    private let blockingRemaining: Double
    private let lock = NSLock()
    private var values: [Double] = []

    init(blockingRemaining: Double) {
        self.blockingRemaining = blockingRemaining
    }

    var recorded: [Double] { lock.withLock { values } }

    func process(snapshot: Snapshot, agent: BalanceNotificationAgent, providerID: String) {
        let remaining = snapshot.officialQuotaWindows.first { $0.kind == .fiveHour }?.remaining ?? -1
        lock.withLock { values.append(remaining) }
        if remaining == blockingRemaining {
            entered.signal()
            gate.wait()
        }
    }
}
