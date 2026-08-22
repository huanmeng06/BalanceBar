import CryptoKit
import Foundation

struct ProviderBalanceProgressIdentity: Hashable {
    let clientID: String
    let providerID: String
    let endpoint: String
    let credentialFingerprint: String

    init(client: AssistantClient, providerID: String, query: BalanceQuery) {
        self.clientID = client.rawValue
        self.providerID = providerID
        self.endpoint = query.url

        let headerMaterial = query.additionalHeaders
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        self.credentialFingerprint = Self.sha256(
            [query.apiKey, headerMaterial].joined(separator: "\u{1F}")
        )
    }

    var storageKey: String {
        Self.sha256([
            clientID,
            providerID,
            endpoint,
            credentialFingerprint
        ].joined(separator: "\u{1F}"))
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum ProviderBalanceProgressError: Error, Equatable {
    case invalidAmount
    case invalidUnit
    case inconsistentUnit(expected: String, actual: String)

    var diagnostic: String {
        switch self {
        case .invalidAmount:
            return "invalid-amount"
        case .invalidUnit:
            return "invalid-unit"
        case .inconsistentUnit:
            return "inconsistent-unit"
        }
    }

    func userVisibleReason(language: AppLanguage) -> String {
        switch self {
        case .invalidAmount:
            return tr(
                "余额数据无效",
                "The balance data is invalid",
                "餘額資料無效",
                "残高データが無効です",
                language: language
            )
        case .invalidUnit:
            return tr(
                "余额单位无效",
                "The balance unit is invalid",
                "餘額單位無效",
                "残高の単位が無効です",
                language: language
            )
        case .inconsistentUnit:
            return tr(
                "余额单位发生变化",
                "The balance unit changed",
                "餘額單位已變更",
                "残高の単位が変わりました",
                language: language
            )
        }
    }
}

final class ProviderBalanceProgressStore {
    private struct State: Codable {
        let baselineCents: Int
        let lastCents: Int
        let unit: String
    }

    static let storageKey = "balancebar.providerBalanceProgress.v1"
    // Keep the default aligned with AppPreferences for users who have not
    // changed the setting yet. The effective value is read from shared
    // UserDefaults for every balance update so the Dashboard setting applies
    // without rebuilding the coordinator.
    static let minimumProgressBaselineCents = 10
    // A third-party zero balance should still render a visible red sliver.
    static let minimumVisibleProgressPercentage = 1.0

    private let defaults: UserDefaults
    private let minimumProgressBaselineCentsProvider: () -> Int
    private let lock = NSLock()
    private var states: [String: State]

    init(
        defaults: UserDefaults = .standard,
        minimumProgressBaselineCentsProvider: (() -> Int)? = nil
    ) {
        self.defaults = defaults
        self.minimumProgressBaselineCentsProvider = minimumProgressBaselineCentsProvider ?? {
            AppPreferences.balanceDisplayThresholdCents(defaults: defaults)
        }
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: State].self, from: data) {
            states = decoded.filter { _, state in
                state.baselineCents >= 0
                    && state.lastCents >= 0
                    && !state.unit.isEmpty
            }
        } else {
            states = [:]
        }
    }

    func update(
        amount: Double,
        unit: String,
        identity: ProviderBalanceProgressIdentity
    ) -> Result<Double, ProviderBalanceProgressError> {
        guard let cents = Self.cents(from: amount) else {
            return .failure(.invalidAmount)
        }
        let normalizedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedUnit.isEmpty else {
            return .failure(.invalidUnit)
        }

        lock.lock()
        defer { lock.unlock() }

        let key = identity.storageKey
        if let previous = states[key], previous.unit != normalizedUnit {
            return .failure(.inconsistentUnit(expected: previous.unit, actual: normalizedUnit))
        }

        let next: State
        if let previous = states[key] {
            let baselineCents = cents >= previous.lastCents + 1
                ? cents
                : previous.baselineCents
            next = State(
                baselineCents: baselineCents,
                lastCents: cents,
                unit: previous.unit
            )
        } else {
            next = State(
                baselineCents: cents,
                lastCents: cents,
                unit: normalizedUnit
            )
        }

        states[key] = next
        persist()
        return .success(percentage(currentCents: cents, baselineCents: next.baselineCents))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func cents(from amount: Double) -> Int? {
        guard amount.isFinite,
              amount <= Double(Int.max) / 100 else { return nil }
        if amount <= 0 { return 0 }

        let rounded = NSDecimalNumber(value: amount).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 2,
                raiseOnExactness: false,
                raiseOnOverflow: true,
                raiseOnUnderflow: true,
                raiseOnDivideByZero: true
            )
        )
        let cents = rounded.multiplying(by: NSDecimalNumber(value: 100))
        guard cents.doubleValue <= Double(Int.max) else { return nil }
        return cents.intValue
    }

    private func percentage(currentCents: Int, baselineCents: Int) -> Double {
        let minimumBaselineCents = max(
            1,
            minimumProgressBaselineCentsProvider()
        )
        guard baselineCents >= minimumBaselineCents else {
            return Self.minimumVisibleProgressPercentage
        }
        let percentage = min(
            100,
            max(0, Double(currentCents) / Double(baselineCents) * 100)
        )
        return percentage == 0 ? Self.minimumVisibleProgressPercentage : percentage
    }
}
