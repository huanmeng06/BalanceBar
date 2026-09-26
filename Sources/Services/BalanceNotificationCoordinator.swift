import AppKit
import Foundation
import UserNotifications

enum BalanceNotificationPermissionState: Equatable {
    case unknown
    case authorized
    case denied
}

protocol BalanceNotificationClient: AnyObject {
    var onResponse: (([AnyHashable: Any]) -> Void)? { get set }
    func authorizationStatus(completion: @escaping (BalanceNotificationPermissionState) -> Void)
    func requestAuthorization(completion: @escaping (Bool) -> Void)
    func deliver(title: String, body: String, userInfo: [AnyHashable: Any])
    func openSettings()
}

/// The only UserNotifications boundary used by the product. Keeping it
/// injectable makes permission, delivery, click routing, and coalescing
/// testable without presenting a system dialog in XCTest.
final class SystemBalanceNotificationClient: NSObject, BalanceNotificationClient, UNUserNotificationCenterDelegate {
    var onResponse: (([AnyHashable: Any]) -> Void)?
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationStatus(completion: @escaping (BalanceNotificationPermissionState) -> Void) {
        center.getNotificationSettings { settings in
            let state: BalanceNotificationPermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                state = .authorized
            case .denied:
                state = .denied
            case .notDetermined:
                state = .unknown
            @unknown default:
                state = .denied
            }
            completion(state)
        }
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion(granted)
        }
    }

    func deliver(title: String, body: String, userInfo: [AnyHashable: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: "balancebar.notification.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                SwitchLog.write(
                    "notification delivery failed; error=\(error.localizedDescription)",
                    level: .warning,
                    category: "notifications"
                )
            }
        }
    }

    func openSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.huanmeng06.BalanceBar.app"
        let urls = [
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?bundleIdentifier=\(bundleID)"),
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings?bundleIdentifier=\(bundleID)")
        ].compactMap { $0 }
        let opened = urls.contains { NSWorkspace.shared.open($0) }
        if !opened {
            SwitchLog.write(
                "notification settings could not be opened",
                level: .warning,
                category: "notifications"
            )
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        onResponse?(response.notification.request.content.userInfo)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

final class BalanceNotificationCoordinator {
    private struct SnapshotKey: Hashable {
        let agent: BalanceNotificationAgent
        let providerID: String
    }

    private struct PendingAlert {
        let alert: BalanceNotificationAlert
        let recovery: Bool
    }

    private let store: BalanceNotificationSettingsStore
    private let client: BalanceNotificationClient
    private let queue = DispatchQueue(label: "local.balancebar.notifications")
    private let queueKey = DispatchSpecificKey<Void>()
    private var permissionStateStorage: BalanceNotificationPermissionState = .unknown
    private var snapshots: [SnapshotKey: Snapshot] = [:]
    private var resourceDescriptors: [SnapshotKey: [BalanceNotificationResourceDescriptor]] = [:]

    var onPermissionStateChanged: ((BalanceNotificationPermissionState) -> Void)?
    var onOpenAgent: ((BalanceNotificationAgent) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        client: BalanceNotificationClient = SystemBalanceNotificationClient()
    ) {
        store = BalanceNotificationSettingsStore(defaults: defaults)
        self.client = client
        queue.setSpecific(key: queueKey, value: ())
        client.onResponse = { [weak self] userInfo in
            guard let self,
                  let raw = userInfo["balancebar.agent"] as? String,
                  let agent = BalanceNotificationAgent(rawValue: raw) else { return }
            self.onOpenAgent?(agent)
        }
        refreshPermission()
    }

    var permissionState: BalanceNotificationPermissionState {
        onQueue { permissionStateStorage }
    }

    var settings: BalanceNotificationSettings {
        onQueue { store.settings }
    }

    func refreshPermission() {
        client.authorizationStatus { [weak self] state in
            guard let self else { return }
            self.onQueue {
                self.permissionStateStorage = state
                self.notifyPermissionStateChanged(state)
                if state == .authorized {
                    self.processStoredSnapshotsOnQueue()
                }
            }
        }
    }

    /// Persist the in-app switch before asking macOS. A denial therefore never
    /// erases the user's rules; the Dashboard can show the disabled state and
    /// offer a direct System Settings action.
    func setGlobalEnabled(_ enabled: Bool) {
        onQueue {
            self.store.update { $0.globalEnabled = enabled }
            guard enabled else { return }
            self.client.authorizationStatus { [weak self] status in
                guard let self else { return }
                self.onQueue {
                    switch status {
                    case .authorized:
                        self.permissionStateStorage = .authorized
                        self.notifyPermissionStateChanged(.authorized)
                        self.processStoredSnapshotsOnQueue()
                    case .denied:
                        self.permissionStateStorage = .denied
                        self.notifyPermissionStateChanged(.denied)
                    case .unknown:
                        self.client.requestAuthorization { [weak self] granted in
                            guard let self else { return }
                            self.onQueue {
                                let next: BalanceNotificationPermissionState = granted ? .authorized : .denied
                                self.permissionStateStorage = next
                                self.notifyPermissionStateChanged(next)
                                if granted { self.processStoredSnapshotsOnQueue() }
                            }
                        }
                    }
                }
            }
        }
    }

    func openSystemSettings() {
        client.openSettings()
    }

    func setAgentEnabled(_ enabled: Bool, agent: BalanceNotificationAgent) {
        onQueue {
            self.store.update { $0.setAgentEnabled(enabled, for: agent) }
            if enabled { self.processStoredSnapshotsOnQueue(agent: agent) }
        }
    }

    func setProviderEnabled(
        _ enabled: Bool,
        agent: BalanceNotificationAgent,
        providerID: String
    ) {
        onQueue {
            self.store.update { $0.setProviderEnabled(enabled, for: agent, providerID: providerID) }
            if enabled { self.processStoredSnapshotsOnQueue(agent: agent, providerID: providerID) }
        }
    }

    func updateRule(
        key: BalanceNotificationResourceKey,
        kind: BalanceNotificationResourceKind,
        unit: String?,
        change: (inout BalanceNotificationResourceRule) -> Void
    ) {
        onQueue {
            self.store.update { settings in
                var rule = settings.rule(for: key, kind: kind, unit: unit)
                let old = rule
                change(&rule)
                rule.firstThreshold = BalanceNotificationResourceRule.normalizedFirstThreshold(
                    rule.firstThreshold,
                    kind: kind
                )
                rule.secondThreshold = BalanceNotificationResourceRule.normalizedSecondThreshold(
                    rule.secondThreshold,
                    firstThreshold: rule.firstThreshold,
                    kind: kind
                )
                // Changing a threshold starts a fresh crossing cycle. This is
                // what makes enabling a rule while already below 20% useful.
                if old.firstThreshold != rule.firstThreshold
                    || old.secondThreshold != rule.secondThreshold
                    || old.secondEnabled != rule.secondEnabled
                    || old.kind != rule.kind
                    || old.unit != rule.unit
                    || old.enabled != rule.enabled {
                    rule.stage = .normal
                    rule.lastValue = nil
                }
                settings.upsert(rule)
            }
            self.processStoredSnapshotsOnQueue(agent: key.agent, providerID: key.providerID)
        }
    }

    func setResourceEnabled(
        _ enabled: Bool,
        key: BalanceNotificationResourceKey,
        kind: BalanceNotificationResourceKind,
        unit: String?
    ) {
        updateRule(key: key, kind: kind, unit: unit) { rule in
            rule.enabled = enabled
        }
    }

    func pause(for duration: TimeInterval?) {
        onQueue {
            self.store.update { settings in
                settings.pauseUntil = duration.map { Date().addingTimeInterval($0) }
            }
        }
    }

    func resume() {
        onQueue { self.store.update { $0.pauseUntil = nil } }
        processStoredSnapshots()
    }

    func resourceDescriptors(
        agent: BalanceNotificationAgent,
        providerID: String
    ) -> [BalanceNotificationResourceDescriptor] {
        onQueue {
            resourceDescriptors[SnapshotKey(agent: agent, providerID: providerID)] ?? []
        }
    }

    /// Called from the existing render/quick-switch callbacks. No timer or
    /// provider request is owned here; one source snapshot is evaluated once.
    func process(
        snapshot: Snapshot,
        agent: BalanceNotificationAgent,
        providerID: String
    ) {
        onQueue {
            self.storeSnapshotOnQueue(snapshot, agent: agent, providerID: providerID)
            self.processSnapshotOnQueue(snapshot, agent: agent, providerID: providerID)
        }
    }

    private func storeSnapshotOnQueue(
        _ snapshot: Snapshot,
        agent: BalanceNotificationAgent,
        providerID: String
    ) {
        let key = SnapshotKey(agent: agent, providerID: providerID)
        snapshots[key] = snapshot
        resourceDescriptors[key] = Self.descriptors(
            from: snapshot,
            agent: agent,
            providerID: providerID
        )
    }

    private func processStoredSnapshotsOnQueue(
        agent: BalanceNotificationAgent? = nil,
        providerID: String? = nil
    ) {
        for (key, snapshot) in snapshots where (agent == nil || key.agent == agent) && (providerID == nil || key.providerID == providerID) {
            processSnapshotOnQueue(snapshot, agent: key.agent, providerID: key.providerID)
        }
    }

    private func processStoredSnapshots() {
        onQueue { self.processStoredSnapshotsOnQueue() }
    }

    private func processSnapshotOnQueue(
        _ snapshot: Snapshot,
        agent: BalanceNotificationAgent,
        providerID: String
    ) {
        guard store.settings.globalEnabled,
              store.settings.isAgentEnabled(agent),
              store.settings.isProviderEnabled(agent, providerID: providerID),
              permissionStateStorage == .authorized else { return }

        if let pauseUntil = store.settings.pauseUntil {
            if pauseUntil > Date() { return }
            store.update { $0.pauseUntil = nil }
        }

        let descriptors = Self.descriptors(from: snapshot, agent: agent, providerID: providerID)
        resourceDescriptors[SnapshotKey(agent: agent, providerID: providerID)] = descriptors
        var pending: [PendingAlert] = []
        store.update { settings in
            for descriptor in descriptors {
                guard let value = descriptor.value else { continue }
                var rule = settings.rule(
                    for: descriptor.key,
                    kind: descriptor.kind,
                    unit: descriptor.unit
                )
                let evaluation = BalanceNotificationThresholdEvaluator.evaluate(
                    rule: rule,
                    value: value,
                    resourceTitle: descriptor.title
                )
                rule = evaluation.rule
                settings.upsert(rule)
                if let alert = evaluation.alert {
                    pending.append(PendingAlert(alert: alert, recovery: false))
                } else if evaluation.recovered && rule.recoveryEnabled {
                    pending.append(PendingAlert(
                        alert: BalanceNotificationAlert(
                            key: descriptor.key,
                            stage: .normal,
                            value: value,
                            unit: descriptor.unit,
                            resourceTitle: descriptor.title
                        ),
                        recovery: true
                    ))
                }
            }
        }
        deliver(pending, agent: agent)
    }

    private func deliver(_ pending: [PendingAlert], agent: BalanceNotificationAgent) {
        guard !pending.isEmpty else { return }
        let alerts = pending.map(\.alert)
        let recoveries = pending.filter(\.recovery)
        let title: String
        let body: String
        if recoveries.count == pending.count {
            title = tr("notifications.recovered_title", arguments: [agent.title])
            body = pending.map { formatValue($0.alert) }.joined(separator: "\n")
        } else if alerts.count == 1 {
            let alert = alerts[0]
            title = tr(
                alert.stage == .second
                    ? "notifications.second_alert_title"
                    : "notifications.first_alert_title",
                arguments: [agent.title, alert.resourceTitle]
            )
            body = formatValue(alert)
        } else {
            title = tr("notifications.batch_title", arguments: [agent.title, String(alerts.count)])
            body = alerts.map { formatValue($0) }.joined(separator: "\n")
        }
        client.deliver(
            title: title,
            body: body,
            userInfo: [
                "balancebar.agent": agent.rawValue,
                "balancebar.route": "agent-window"
            ]
        )
    }

    private func formatValue(_ alert: BalanceNotificationAlert) -> String {
        switch alert.key.agent {
        case .gpt, .claude, .gemini, .grok:
            if alert.unit == "%" || alert.unit == nil {
                return tr(
                    "notifications.quota_value",
                    arguments: [alert.resourceTitle, String(format: "%.0f", alert.value)]
                )
            }
            return tr(
                "notifications.balance_value",
                arguments: [alert.resourceTitle, formatBalance(alert.value, unit: alert.unit)]
            )
        }
    }

    private func formatBalance(_ value: Double, unit: String?) -> String {
        let number = String(format: "%.2f", value)
        return "\(unit ?? "")\(number)"
    }

    private func notifyPermissionStateChanged(_ state: BalanceNotificationPermissionState) {
        let callback = onPermissionStateChanged
        if Thread.isMainThread {
            callback?(state)
        } else {
            DispatchQueue.main.async { callback?(state) }
        }
    }

    private func onQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return work()
        }
        return queue.sync(execute: work)
    }

    private static func descriptors(
        from snapshot: Snapshot,
        agent: BalanceNotificationAgent,
        providerID: String
    ) -> [BalanceNotificationResourceDescriptor] {
        switch snapshot.kind {
        case .official:
            return snapshot.officialQuotaWindows.enumerated().map { index, window in
                let id: String
                switch window.kind {
                case .fiveHour: id = "five-hour"
                case .sevenDay: id = "weekly"
                case .other: id = "quota-\(index)"
                }
                let title = window.label.isEmpty ? window.daysText : window.label
                return BalanceNotificationResourceDescriptor(
                    key: BalanceNotificationResourceKey(agent: agent, providerID: providerID, resourceID: id),
                    title: title,
                    kind: .quotaPercent,
                    value: window.remaining,
                    unit: "%"
                )
            }
        case .balance:
            return [BalanceNotificationResourceDescriptor(
                key: BalanceNotificationResourceKey(agent: agent, providerID: providerID, resourceID: "balance"),
                title: tr("notifications.balance_resource"),
                kind: .balance,
                value: snapshot.amount,
                unit: snapshot.unit
            )]
        case .placeholder, .error:
            return []
        }
    }
}
