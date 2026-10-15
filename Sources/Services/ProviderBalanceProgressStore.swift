import CryptoKit
import Foundation

struct ProviderBalanceProgressIdentity: Hashable {
    let clientID: String
    let providerID: String
    let endpoint: String
    let credentialFingerprint: String
    let walletID: String

    init(client: AssistantClient, providerID: String, query: BalanceQuery) {
        let fields: [Any] = [client.rawValue, query.url, query.apiKey,
            query.additionalHeaders.sorted { $0.key < $1.key }.map { [$0.key, $0.value] },
            query.isRightCode, query.subscriptionPrefix, query.isNewAPI,
            String(describing: query.nativeBalanceProvider)]
        let data = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        self.walletID = Self.sha256(data.base64EncodedString())
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
            return tr(.keyProviderBalanceProgressStoreTheBalanceDataIsInvalid, language: language)
        case .invalidUnit:
            return tr(.keyProviderBalanceProgressStoreTheBalanceUnitIsInvalid, language: language)
        case .inconsistentUnit:
            return tr(.keyProviderBalanceProgressStoreTheBalanceUnitChanged, language: language)
        }
    }
}

final class ProviderBalanceProgressStore {
    private struct State: Codable, Equatable {
        let baselineCents: Int
        let lastCents: Int
        let unit: String
        var recharge: BalanceRecharge? = nil
        var observedAt: Date? = nil
        var sampleSequence: UInt64? = nil
    }

    struct Observation {
        let amount: Double
        let unit: String
        let progress: Double
        let recharge: BalanceRecharge?
        let observedAt: Date
        let accepted: Bool
    }

    static let storageKey = "balancebar.providerBalanceProgress.v1"
    static let minimumProgressBaselineCents = 10
    static let minimumVisibleProgressPercentage = 1.0
    private let defaults: UserDefaults
    private let minimumProgressBaselineCentsProvider: () -> Int
    private let lock = NSLock()
    private var states: [String: State]
    private var sequence: UInt64 = 0
    private var preparedWallets: Set<String> = []

    init(defaults: UserDefaults = .standard, minimumProgressBaselineCentsProvider: (() -> Int)? = nil) {
        self.defaults = defaults
        self.minimumProgressBaselineCentsProvider = minimumProgressBaselineCentsProvider ?? {
            AppPreferences.balanceDisplayThresholdCents(defaults: defaults)
        }
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: State].self, from: data) {
            states = decoded.filter { $0.value.baselineCents >= 0 && $0.value.lastCents >= 0 && !$0.value.unit.isEmpty }
        } else { states = [:] }
        sequence = states.values.compactMap(\.sampleSequence).max() ?? 0
    }

    /// Reserve before dispatch, not on completion: an older transport cannot
    /// turn an out-of-order balance into a fictitious recharge.
    func beginSample() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        return sequence
    }

    private func walletKey(_ identity: ProviderBalanceProgressIdentity, unit: String) -> String {
        "wallet:" + identity.walletID + ":" + unit
    }

    /// Legacy per-Provider records have no timestamp. Migrate only agreeing
    /// records, and never manufacture recharge metadata for them.
    func prepareMigration(identities: [ProviderBalanceProgressIdentity]) {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for (wallet, peers) in Dictionary(grouping: identities, by: \.walletID) {
            guard preparedWallets.insert(wallet).inserted else { continue }
            let legacy = peers.compactMap { states[$0.storageKey] }
            guard let first = legacy.first,
                  legacy.allSatisfy({ $0.baselineCents == first.baselineCents && $0.lastCents == first.lastCents && $0.unit == first.unit }),
                  let identity = peers.first else { continue }
            let key = walletKey(identity, unit: first.unit)
            if states[key] == nil {
                states[key] = State(baselineCents: first.baselineCents, lastCents: first.lastCents, unit: first.unit)
                changed = true
            }
        }
        if changed { persist() }
    }

    func update(amount: Double, unit: String, identity: ProviderBalanceProgressIdentity) -> Result<Double, ProviderBalanceProgressError> {
        observe(amount: amount, unit: unit, identity: identity, sampleSequence: beginSample(), observedAt: Date()).map(\.progress)
    }

    func observe(amount: Double, unit: String, identity: ProviderBalanceProgressIdentity,
                 sampleSequence: UInt64, observedAt: Date) -> Result<Observation, ProviderBalanceProgressError> {
        guard let cents = Self.cents(from: amount) else { return .failure(.invalidAmount) }
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !unit.isEmpty else { return .failure(.invalidUnit) }
        lock.lock(); defer { lock.unlock() }
        let key = walletKey(identity, unit: unit)
        let previous = states[key]
        let accepted = sampleSequence > (previous?.sampleSequence ?? 0)
        var next = previous ?? State(baselineCents: cents, lastCents: cents, unit: unit)
        if accepted {
            if let previous, cents > previous.lastCents {
                next.recharge = BalanceRecharge(amountCents: cents - previous.lastCents, observedAt: observedAt)
                next = State(baselineCents: cents, lastCents: cents, unit: unit, recharge: next.recharge,
                    observedAt: observedAt, sampleSequence: sampleSequence)
            } else {
                next = State(baselineCents: next.baselineCents, lastCents: cents, unit: unit, recharge: next.recharge,
                    observedAt: observedAt, sampleSequence: sampleSequence)
            }
            states[key] = next
            persist()
        }
        return .success(Observation(amount: Double(next.lastCents) / 100, unit: next.unit,
            progress: percentage(currentCents: next.lastCents, baselineCents: next.baselineCents, rechargeCents: next.recharge?.amountCents),
            recharge: next.recharge, observedAt: next.observedAt ?? observedAt, accepted: accepted))
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

    private func percentage(currentCents: Int, baselineCents: Int, rechargeCents: Int? = nil) -> Double {
        let minimumBaselineCents = max(
            1,
            minimumProgressBaselineCentsProvider()
        )
        guard baselineCents >= minimumBaselineCents else {
            return Self.minimumVisibleProgressPercentage
        }
        let percentage = min(
            100,
            max(0, Double(currentCents) / Double(rechargeCents ?? baselineCents) * 100)
        )
        return percentage == 0 ? Self.minimumVisibleProgressPercentage : percentage
    }
}
