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
}
