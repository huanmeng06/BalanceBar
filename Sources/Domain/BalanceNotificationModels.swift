import Foundation

/// The notification hierarchy is deliberately independent from
/// `AssistantClient`. CC Switch currently exposes three client integrations,
/// while the Dashboard contract reserves a row for Gemini as well.
enum BalanceNotificationAgent: String, CaseIterable, Codable, Hashable {
    case gpt
    case claude
    case gemini
    case grok

    /// Dashboard rows currently represent the three integrations with live
    /// provider refresh sources. Gemini remains in the persisted model for
    /// forward compatibility with the notification contract.
    static let dashboardCases: [Self] = [.gpt, .claude, .grok]

    var title: String {
        switch self {
        case .gpt: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        }
    }

    var assistantClient: AssistantClient? {
        switch self {
        case .gpt: return .codex
        case .claude: return .claude
        case .gemini: return nil
        case .grok: return .grok
        }
    }
}

enum BalanceNotificationResourceKind: String, Codable, Hashable {
    case quotaPercent
    case balance
}

struct BalanceNotificationResourceKey: Codable, Hashable, Equatable {
    let agent: BalanceNotificationAgent
    let providerID: String
    let resourceID: String

    init(agent: BalanceNotificationAgent, providerID: String, resourceID: String) {
        self.agent = agent
        self.providerID = providerID
        self.resourceID = resourceID
    }

    var storageKey: String {
        "\(agent.rawValue)|\(providerID)|\(resourceID)"
    }
}

enum BalanceNotificationAlertStage: String, Codable, Equatable {
    case normal
    case first
    case second
}

struct BalanceNotificationResourceRule: Codable, Equatable {
    let key: BalanceNotificationResourceKey
    var kind: BalanceNotificationResourceKind
    /// The source unit is stored with the rule so a balance threshold never
    /// silently changes currency when CC Switch changes provider data.
    var unit: String?
    var enabled: Bool
    var firstThreshold: Double
    var secondEnabled: Bool
    var secondThreshold: Double
    var recoveryEnabled: Bool
    var stage: BalanceNotificationAlertStage
    var lastValue: Double?

    init(
        key: BalanceNotificationResourceKey,
        kind: BalanceNotificationResourceKind,
        unit: String? = nil,
        enabled: Bool = true,
        firstThreshold: Double? = nil,
        secondEnabled: Bool = false,
        secondThreshold: Double? = nil,
        recoveryEnabled: Bool = false,
        stage: BalanceNotificationAlertStage = .normal,
        lastValue: Double? = nil
    ) {
        self.key = key
        self.kind = kind
        self.unit = unit
        self.enabled = enabled
        let defaultFirst = kind == .quotaPercent ? 20 : 5
        let resolvedFirst = firstThreshold ?? Double(defaultFirst)
        self.firstThreshold = Self.normalizedFirstThreshold(resolvedFirst, kind: kind)
        self.secondEnabled = secondEnabled
        let defaultSecond = kind == .quotaPercent ? 5 : max(0.01, self.firstThreshold / 2)
        let resolvedSecond = secondThreshold ?? defaultSecond
        self.secondThreshold = Self.normalizedSecondThreshold(
            resolvedSecond,
            firstThreshold: self.firstThreshold,
            kind: kind
        )
        self.recoveryEnabled = recoveryEnabled
        self.stage = stage
        self.lastValue = lastValue?.isFinite == true ? lastValue : nil
    }

    static func normalizedFirstThreshold(
        _ value: Double,
        kind: BalanceNotificationResourceKind
    ) -> Double {
        guard value.isFinite else { return kind == .quotaPercent ? 20 : 5 }
        switch kind {
        case .quotaPercent:
            return min(100, max(0, value.rounded()))
        case .balance:
            return max(0, (value * 100).rounded() / 100)
        }
    }

    static func normalizedSecondThreshold(
        _ value: Double,
        firstThreshold: Double,
        kind: BalanceNotificationResourceKind
    ) -> Double {
        let normalized: Double
        switch kind {
        case .quotaPercent:
            normalized = min(100, max(0, value.rounded()))
        case .balance:
            normalized = max(0, (value * 100).rounded() / 100)
        }
        return min(normalized, max(0, firstThreshold - (kind == .quotaPercent ? 1 : 0.01)))
    }

    mutating func update(
        kind: BalanceNotificationResourceKind,
        unit: String?,
        enabled: Bool? = nil,
        firstThreshold: Double? = nil,
        secondEnabled: Bool? = nil,
        secondThreshold: Double? = nil,
        recoveryEnabled: Bool? = nil,
        resetAlertState: Bool = false
    ) {
        self.kind = kind
        if let unit, !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.unit = unit
        }
        if let enabled { self.enabled = enabled }
        if let firstThreshold {
            self.firstThreshold = Self.normalizedFirstThreshold(firstThreshold, kind: kind)
        }
        if let secondEnabled { self.secondEnabled = secondEnabled }
        if let secondThreshold {
            self.secondThreshold = Self.normalizedSecondThreshold(
                secondThreshold,
                firstThreshold: self.firstThreshold,
                kind: kind
            )
        }
        if let recoveryEnabled { self.recoveryEnabled = recoveryEnabled }
        self.secondThreshold = Self.normalizedSecondThreshold(
            self.secondThreshold,
            firstThreshold: self.firstThreshold,
            kind: kind
        )
        if resetAlertState {
            stage = .normal
            lastValue = nil
        }
    }
}

struct BalanceNotificationAlert: Equatable {
    let key: BalanceNotificationResourceKey
    let stage: BalanceNotificationAlertStage
    let value: Double
    let unit: String?
    let resourceTitle: String
}

struct BalanceNotificationResourceDescriptor: Equatable {
    let key: BalanceNotificationResourceKey
    let title: String
    let kind: BalanceNotificationResourceKind
    let value: Double?
    let unit: String?
}

struct BalanceNotificationEvaluation: Equatable {
    let rule: BalanceNotificationResourceRule
    let alert: BalanceNotificationAlert?
    let recovered: Bool
}

/// Stateless threshold crossing logic. The caller persists the returned rule
/// after every snapshot so a restart cannot replay an already delivered alert.
enum BalanceNotificationThresholdEvaluator {
    static func evaluate(
        rule input: BalanceNotificationResourceRule,
        value: Double,
        resourceTitle: String
    ) -> BalanceNotificationEvaluation {
        var rule = input
        guard value.isFinite else {
            return BalanceNotificationEvaluation(rule: rule, alert: nil, recovered: false)
        }

        let wasAlerted = rule.stage != .normal
        let recoveryThreshold = Self.recoveryThreshold(for: rule)
        if wasAlerted, value >= recoveryThreshold {
            rule.stage = .normal
            rule.lastValue = value
            return BalanceNotificationEvaluation(rule: rule, alert: nil, recovered: true)
        }

        let previous = rule.lastValue
        rule.lastValue = value
        guard rule.enabled else {
            return BalanceNotificationEvaluation(rule: rule, alert: nil, recovered: false)
        }

        switch rule.stage {
        case .normal:
            guard value <= rule.firstThreshold,
                  previous.map({ $0 > rule.firstThreshold }) ?? true else {
                return BalanceNotificationEvaluation(rule: rule, alert: nil, recovered: false)
            }
            rule.stage = .first
            return BalanceNotificationEvaluation(
                rule: rule,
                alert: BalanceNotificationAlert(
                    key: rule.key,
                    stage: .first,
                    value: value,
                    unit: rule.unit,
                    resourceTitle: resourceTitle
                ),
                recovered: false
            )
        case .first:
            guard rule.secondEnabled,
                  value <= rule.secondThreshold,
                  previous.map({ $0 > rule.secondThreshold }) ?? true else {
                return BalanceNotificationEvaluation(rule: rule, alert: nil, recovered: false)
            }
            rule.stage = .second
            return BalanceNotificationEvaluation(
                rule: rule,
                alert: BalanceNotificationAlert(
                    key: rule.key,
                    stage: .second,
                    value: value,
                    unit: rule.unit,
                    resourceTitle: resourceTitle
                ),
                recovered: false
            )
        case .second:
            return BalanceNotificationEvaluation(rule: rule, alert: nil, recovered: false)
        }
    }

    static func recoveryThreshold(for rule: BalanceNotificationResourceRule) -> Double {
        switch rule.kind {
        case .quotaPercent:
            return min(100, rule.firstThreshold + max(1, rule.firstThreshold * 0.05))
        case .balance:
            return rule.firstThreshold + max(0.01, rule.firstThreshold * 0.05)
        }
    }
}

struct BalanceNotificationProviderPreference: Codable, Equatable {
    let agent: BalanceNotificationAgent
    let providerID: String
    var enabled: Bool
}

struct BalanceNotificationSettings: Codable, Equatable {
    var globalEnabled = false
    var agentEnabled: [String: Bool] = Dictionary(
        uniqueKeysWithValues: BalanceNotificationAgent.allCases.map { ($0.rawValue, false) }
    )
    var providerPreferences: [BalanceNotificationProviderPreference] = []
    var resourceRules: [BalanceNotificationResourceRule] = []
    var pauseUntil: Date?

    func isAgentEnabled(_ agent: BalanceNotificationAgent) -> Bool {
        agentEnabled[agent.rawValue] ?? false
    }

    mutating func setAgentEnabled(_ enabled: Bool, for agent: BalanceNotificationAgent) {
        agentEnabled[agent.rawValue] = enabled
    }

    func isProviderEnabled(_ agent: BalanceNotificationAgent, providerID: String) -> Bool {
        providerPreferences.first {
            $0.agent == agent && $0.providerID == providerID
        }?.enabled ?? false
    }

    mutating func setProviderEnabled(
        _ enabled: Bool,
        for agent: BalanceNotificationAgent,
        providerID: String
    ) {
        if let index = providerPreferences.firstIndex(where: {
            $0.agent == agent && $0.providerID == providerID
        }) {
            providerPreferences[index].enabled = enabled
        } else {
            providerPreferences.append(
                BalanceNotificationProviderPreference(
                    agent: agent,
                    providerID: providerID,
                    enabled: enabled
                )
            )
        }
    }

    func rule(for key: BalanceNotificationResourceKey) -> BalanceNotificationResourceRule? {
        resourceRules.first { $0.key == key }
    }

    mutating func rule(
        for key: BalanceNotificationResourceKey,
        kind: BalanceNotificationResourceKind,
        unit: String?
    ) -> BalanceNotificationResourceRule {
        if let existing = rule(for: key) {
            var copy = existing
            copy.update(kind: kind, unit: unit)
            return copy
        }
        return BalanceNotificationResourceRule(key: key, kind: kind, unit: unit)
    }

    mutating func upsert(_ rule: BalanceNotificationResourceRule) {
        if let index = resourceRules.firstIndex(where: { $0.key == rule.key }) {
            resourceRules[index] = rule
        } else {
            resourceRules.append(rule)
        }
    }

    mutating func resetTransientState() {
        for index in resourceRules.indices {
            resourceRules[index].stage = .normal
            resourceRules[index].lastValue = nil
        }
    }
}

final class BalanceNotificationSettingsStore {
    static let storageKey = "balancebar.notificationSettings.v1"

    private let defaults: UserDefaults
    private(set) var settings: BalanceNotificationSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(BalanceNotificationSettings.self, from: data) {
            settings = decoded
        } else {
            settings = BalanceNotificationSettings()
        }
        normalize()
    }

    func update(_ change: (inout BalanceNotificationSettings) -> Void) {
        var next = settings
        change(&next)
        settings = next
        persist()
    }

    func replace(_ value: BalanceNotificationSettings) {
        settings = value
        normalize()
        persist()
    }

    private func normalize() {
        for agent in BalanceNotificationAgent.allCases where settings.agentEnabled[agent.rawValue] == nil {
            settings.agentEnabled[agent.rawValue] = false
        }
        settings.resourceRules = settings.resourceRules.map { rule in
            var normalized = rule
            normalized.firstThreshold = BalanceNotificationResourceRule.normalizedFirstThreshold(
                rule.firstThreshold,
                kind: rule.kind
            )
            normalized.secondThreshold = BalanceNotificationResourceRule.normalizedSecondThreshold(
                rule.secondThreshold,
                firstThreshold: normalized.firstThreshold,
                kind: normalized.kind
            )
            return normalized
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
