import Foundation
import XCTest
@testable import BalanceBar

final class BalanceNotificationCoordinatorTests: XCTestCase {
    func testThresholdCrossingSecondAlertAndHysteresisRearm() {
        let key = BalanceNotificationResourceKey(agent: .claude, providerID: "p", resourceID: "weekly")
        var rule = BalanceNotificationResourceRule(
            key: key,
            kind: .quotaPercent,
            firstThreshold: 20,
            secondEnabled: true,
            secondThreshold: 5
        )

        var evaluation = BalanceNotificationThresholdEvaluator.evaluate(rule: rule, value: 21, resourceTitle: "Weekly")
        XCTAssertNil(evaluation.alert)
        rule = evaluation.rule
        evaluation = BalanceNotificationThresholdEvaluator.evaluate(rule: rule, value: 19, resourceTitle: "Weekly")
        XCTAssertEqual(evaluation.alert?.stage, .first)
        rule = evaluation.rule
        evaluation = BalanceNotificationThresholdEvaluator.evaluate(rule: rule, value: 19.8, resourceTitle: "Weekly")
        XCTAssertNil(evaluation.alert, "threshold jitter must not re-arm")
        rule = evaluation.rule
        evaluation = BalanceNotificationThresholdEvaluator.evaluate(rule: rule, value: 4, resourceTitle: "Weekly")
        XCTAssertEqual(evaluation.alert?.stage, .second)
        rule = evaluation.rule
        evaluation = BalanceNotificationThresholdEvaluator.evaluate(rule: rule, value: 100, resourceTitle: "Weekly")
        XCTAssertTrue(evaluation.recovered)
        rule = evaluation.rule
        evaluation = BalanceNotificationThresholdEvaluator.evaluate(rule: rule, value: 19, resourceTitle: "Weekly")
        XCTAssertEqual(evaluation.alert?.stage, .first)
    }

    func testSettingsStorePersistsGlobalAgentProviderAndRules() {
        let suiteName = "BalanceNotificationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = BalanceNotificationResourceKey(agent: .gpt, providerID: "openai", resourceID: "five-hour")
        let store = BalanceNotificationSettingsStore(defaults: defaults)
        store.update { settings in
            settings.globalEnabled = true
            settings.setAgentEnabled(true, for: .gpt)
            settings.setProviderEnabled(true, for: .gpt, providerID: "openai")
            settings.upsert(BalanceNotificationResourceRule(key: key, kind: .quotaPercent, firstThreshold: 25))
        }

        let reloaded = BalanceNotificationSettingsStore(defaults: defaults).settings
        XCTAssertTrue(reloaded.globalEnabled)
        XCTAssertTrue(reloaded.isAgentEnabled(.gpt))
        XCTAssertTrue(reloaded.isProviderEnabled(.gpt, providerID: "openai"))
        XCTAssertEqual(reloaded.rule(for: key)?.firstThreshold, 25)
    }

    func testPermissionDenialKeepsConfigurationAndCoalescesAgentResources() {
        let client = FakeBalanceNotificationClient(status: .unknown, requestResult: false)
        let suiteName = "BalanceNotificationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = BalanceNotificationCoordinator(defaults: defaults, client: client)
        coordinator.setGlobalEnabled(true)
        XCTAssertEqual(coordinator.permissionState, .denied)
        XCTAssertTrue(coordinator.settings.globalEnabled)
        XCTAssertEqual(client.deliveries.count, 0)

        let authorized = FakeBalanceNotificationClient(status: .authorized, requestResult: true)
        let live = BalanceNotificationCoordinator(defaults: defaults, client: authorized)
        live.setAgentEnabled(true, agent: .claude)
        live.setProviderEnabled(true, agent: .claude, providerID: "provider-a")
        let snapshot = Snapshot.official(
            "Provider A",
            10,
            "Weekly",
            nil,
            Date(),
            windows: [
                OfficialQuotaWindow(kind: .fiveHour, remaining: 18, label: "5h", daysText: "5h", reset: nil, durationSeconds: nil),
                OfficialQuotaWindow(kind: .sevenDay, remaining: 17, label: "Weekly", daysText: "Weekly", reset: nil, durationSeconds: nil)
            ]
        )
        live.process(snapshot: snapshot, agent: .claude, providerID: "provider-a")
        XCTAssertEqual(authorized.deliveries.count, 1, "same-agent resources should be coalesced")
        XCTAssertTrue(authorized.deliveries[0].body.contains("5h"))
        XCTAssertTrue(authorized.deliveries[0].body.contains("Weekly"))
    }

    func testNotificationClickRoutesOnlyToAgentCallback() {
        let client = FakeBalanceNotificationClient(status: .authorized, requestResult: true)
        let coordinator = BalanceNotificationCoordinator(client: client)
        var opened: BalanceNotificationAgent?
        coordinator.onOpenAgent = { opened = $0 }
        client.simulateResponse(["balancebar.agent": "grok", "balancebar.route": "agent-window"])
        XCTAssertEqual(opened, .grok)
    }
}

private final class FakeBalanceNotificationClient: BalanceNotificationClient {
    var onResponse: (([AnyHashable: Any]) -> Void)?
    var status: BalanceNotificationPermissionState
    let requestResult: Bool
    private(set) var deliveries: [(title: String, body: String, userInfo: [AnyHashable: Any])] = []

    init(status: BalanceNotificationPermissionState, requestResult: Bool) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus(completion: @escaping (BalanceNotificationPermissionState) -> Void) {
        completion(status)
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        status = requestResult ? .authorized : .denied
        completion(requestResult)
    }

    func deliver(title: String, body: String, userInfo: [AnyHashable: Any]) {
        deliveries.append((title, body, userInfo))
    }

    func openSettings() {}

    func simulateResponse(_ userInfo: [AnyHashable: Any]) {
        onResponse?(userInfo)
    }
}
