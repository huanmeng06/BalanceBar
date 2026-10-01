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

    func testSettingsChangesWaitForNextSnapshotBeforeDelivering() {
        let client = FakeBalanceNotificationClient(status: .authorized, requestResult: true)
        let suiteName = "BalanceNotificationCoordinatorTests.SettingsChanges.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = BalanceNotificationCoordinator(defaults: defaults, client: client)
        let snapshot = Snapshot.official(
            "Provider",
            10,
            "Weekly",
            nil,
            Date(),
            windows: [
                OfficialQuotaWindow(
                    kind: .fiveHour,
                    remaining: 18,
                    label: "5h",
                    daysText: "5h",
                    reset: nil,
                    durationSeconds: nil
                )
            ]
        )

        // Store a low snapshot while notifications are not configured yet.
        coordinator.process(snapshot: snapshot, agent: .gpt, providerID: "openai")
        coordinator.setGlobalEnabled(true)
        coordinator.setAgentEnabled(true, agent: .gpt)
        coordinator.setProviderEnabled(true, agent: .gpt, providerID: "openai")

        XCTAssertTrue(client.deliveries.isEmpty)

        // A real refresh is the first point at which the new settings may alert.
        coordinator.process(snapshot: snapshot, agent: .gpt, providerID: "openai")
        XCTAssertEqual(client.deliveries.count, 1)
    }

    func testApplyGlobalRulesRestoresInheritanceWithoutReenablingResources() {
        let client = FakeBalanceNotificationClient(status: .authorized, requestResult: true)
        let suiteName = "BalanceNotificationCoordinatorTests.ApplyGlobalRules.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = BalanceNotificationResourceKey(
            agent: .gpt,
            providerID: "provider-a",
            resourceID: "five-hour"
        )
        let orphanKey = BalanceNotificationResourceKey(
            agent: .gpt,
            providerID: "deleted-provider",
            resourceID: "five-hour"
        )
        let store = BalanceNotificationSettingsStore(defaults: defaults)
        store.update { settings in
            settings.upsert(BalanceNotificationResourceRule(
                key: key,
                kind: .quotaPercent,
                enabled: false,
                firstThreshold: 10,
                secondEnabled: true,
                secondThreshold: 2,
                usesGlobalDefaults: false
            ))
            settings.upsert(BalanceNotificationResourceRule(
                key: orphanKey,
                kind: .quotaPercent,
                enabled: false,
                firstThreshold: 8,
                secondEnabled: true,
                secondThreshold: 3,
                usesGlobalDefaults: false
            ))
        }

        let coordinator = BalanceNotificationCoordinator(defaults: defaults, client: client)
        coordinator.applyGlobalRules(to: .gpt)

        let restored = try! XCTUnwrap(coordinator.settings.rule(for: key))
        XCTAssertFalse(restored.enabled)
        XCTAssertTrue(restored.usesGlobalDefaults)
        XCTAssertEqual(restored.firstThreshold, coordinator.settings.globalFiveHourFirstThreshold)
        XCTAssertEqual(restored.secondThreshold, coordinator.settings.globalFiveHourSecondThreshold)
        XCTAssertEqual(restored.secondEnabled, coordinator.settings.globalFiveHourSecondThreshold > 0)

        let orphan = try! XCTUnwrap(coordinator.settings.rule(for: orphanKey))
        XCTAssertFalse(orphan.enabled)
        XCTAssertTrue(orphan.usesGlobalDefaults)
        XCTAssertEqual(orphan.firstThreshold, coordinator.settings.globalFiveHourFirstThreshold)
        XCTAssertFalse(coordinator.settings.hasCustomRules(for: .gpt))
    }

    func testProviderOffDoesNotDeliverAndRearmsAfterReset() {
        let client = FakeBalanceNotificationClient(status: .authorized, requestResult: true)
        let suiteName = "BalanceNotificationCoordinatorTests.ProviderGate.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = BalanceNotificationCoordinator(defaults: defaults, client: client)
        coordinator.setGlobalEnabled(true)
        coordinator.setAgentEnabled(true, agent: .gpt)
        coordinator.setProviderEnabled(true, agent: .gpt, providerID: "openai")
        let weeklyKey = BalanceNotificationResourceKey(
            agent: .gpt,
            providerID: "openai",
            resourceID: "weekly"
        )
        coordinator.updateRule(key: weeklyKey, kind: .quotaPercent, unit: "%") { rule in
            rule.firstThreshold = 20
            rule.secondEnabled = true
            rule.secondThreshold = 5
        }

        func snapshot(_ fiveHour: Double, _ weekly: Double) -> Snapshot {
            Snapshot.official(
                "Provider",
                weekly,
                "Weekly",
                nil,
                Date(),
                windows: [
                    OfficialQuotaWindow(
                        kind: .fiveHour,
                        remaining: fiveHour,
                        label: "5h",
                        daysText: "5h",
                        reset: nil,
                        durationSeconds: nil
                    ),
                    OfficialQuotaWindow(
                        kind: .sevenDay,
                        remaining: weekly,
                        label: "Weekly",
                        daysText: "Weekly",
                        reset: nil,
                        durationSeconds: nil
                    )
                ]
            )
        }

        coordinator.process(snapshot: snapshot(80, 21), agent: .gpt, providerID: "openai")
        coordinator.process(snapshot: snapshot(80, 19), agent: .gpt, providerID: "openai")
        coordinator.process(snapshot: snapshot(80, 4), agent: .gpt, providerID: "openai")
        XCTAssertEqual(client.deliveries.count, 2)
        XCTAssertEqual(coordinator.settings.rule(for: weeklyKey)?.stage, .second)

        coordinator.setProviderEnabled(false, agent: .gpt, providerID: "openai")
        coordinator.process(snapshot: snapshot(80, 4), agent: .gpt, providerID: "openai")
        XCTAssertEqual(client.deliveries.count, 2, "Provider OFF must not deliver")
        XCTAssertEqual(coordinator.settings.rule(for: weeklyKey)?.stage, .second)

        coordinator.process(snapshot: snapshot(80, 100), agent: .gpt, providerID: "openai")
        XCTAssertEqual(client.deliveries.count, 2, "reset while Provider is OFF must not deliver")
        XCTAssertEqual(coordinator.settings.rule(for: weeklyKey)?.stage, .normal)

        coordinator.setProviderEnabled(true, agent: .gpt, providerID: "openai")
        coordinator.process(snapshot: snapshot(80, 15), agent: .gpt, providerID: "openai")
        XCTAssertEqual(client.deliveries.count, 3, "re-armed cycle should first-alert after Provider ON")
        XCTAssertEqual(coordinator.settings.rule(for: weeklyKey)?.stage, .first)
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
        XCTAssertFalse(authorized.deliveries[0].body.isEmpty)
        XCTAssertTrue(authorized.deliveries[0].title.contains("Claude"))
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
