import CryptoKit
import Foundation

struct ProviderBalanceProgressIdentity: Hashable {
    let clientID: String
    let providerID: String
    let endpoint: String
    let credentialFingerprint: String
    /// Retained query fingerprint for legacy migration, never the Codex name group.
    let walletID: String
    let accountingID: String
    let usesNameScope: Bool

    init(client: AssistantClient, providerID: String, query: BalanceQuery, providerName: String? = nil) {
        let fields: [Any] = [client.rawValue, query.url, query.apiKey,
            query.additionalHeaders.sorted { $0.key < $1.key }.map { [$0.key, $0.value] },
            query.isRightCode, query.subscriptionPrefix, query.isNewAPI,
            String(describing: query.nativeBalanceProvider)]
        let data = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        self.walletID = Self.sha256(data.base64EncodedString())
        self.usesNameScope = false
        // Visual name grouping never proves account ownership. Codex histories
        // include Provider ID and the complete authenticated query identity.
        self.accountingID = client == .codex
            ? "provider-v2:" + Self.sha256(providerID + "|" + walletID)
            : walletID
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

    /// Exact CC Switch name: preserve case and surrounding whitespace.
    /// Blank names never identify a shared group.
    static func nameScope(client: AssistantClient, name: String?) -> String? {
        guard client == .codex, let name,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let data = try? JSONSerialization.data(withJSONObject: [client.rawValue, name])
        return "name:" + sha256((data ?? Data()).base64EncodedString())
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
        var peakCents: Int? = nil
        var baselineObservedAt: Date? = nil
    }

    struct Observation {
        let amount: Double
        let unit: String
        let progress: Double
        let recharge: BalanceRecharge?
        let observedAt: Date
        let accepted: Bool
        let progressContext: BalanceProgressContext

        var displayProgress: Double { progress }
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
    // Migration is one-way: a renamed group must not reimport the same old
    // query record, including after a restart or after conflicting records.
    private var migratedNameScopes: Set<String>
    private var consumedLegacyKeys: Set<String>
    private static let migrationKey = "balancebar.providerBalanceProgress.nameMigration.v1"

    init(defaults: UserDefaults = .standard, minimumProgressBaselineCentsProvider: (() -> Int)? = nil) {
        self.defaults = defaults
        let migration = defaults.dictionary(forKey: Self.migrationKey)
        migratedNameScopes = Set(migration?["scopes"] as? [String] ?? [])
        consumedLegacyKeys = Set(migration?["consumed"] as? [String] ?? [])
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
        "wallet:" + identity.accountingID + ":" + unit
    }

    func needsNameMigration(_ identity: ProviderBalanceProgressIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return identity.usesNameScope && !migratedNameScopes.contains(identity.accountingID)
    }

    /// Called with the complete source list before dispatch. Only agreeing old
    /// records migrate; ambiguity establishes a new live baseline, not a recharge.
    func prepareMigration(identities: [ProviderBalanceProgressIdentity]) {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        let owners = Dictionary(grouping: identities, by: \.walletID)
        for (scope, peers) in Dictionary(grouping: identities, by: \.accountingID) {
            guard let identity = peers.first else { continue }
            if identity.usesNameScope {
                guard migratedNameScopes.insert(scope).inserted else { continue }
                var keys: Set<String> = []
                var consumed: Set<String> = []
                var ambiguous = false
                for peer in peers {
                    let prefix = "wallet:" + peer.walletID + ":"
                    let queryKeys = states.keys.filter { $0.hasPrefix(prefix) }
                    keys.formUnion(queryKeys.isEmpty ? [peer.storageKey] : queryKeys)
                    consumed.formUnion(queryKeys + [peer.storageKey])
                    if Set((owners[peer.walletID] ?? []).map(\.accountingID)).count > 1 { ambiguous = true }
                }
                let alreadyConsumed = !consumed.isDisjoint(with: consumedLegacyKeys)
                consumedLegacyKeys.formUnion(consumed)
                changed = true
                guard !ambiguous, !alreadyConsumed else { continue }
                let old = keys.compactMap { states[$0] }
                for (unit, records) in Dictionary(grouping: old, by: \.unit) {
                    guard let first = records.first,
                          records.allSatisfy({ $0.baselineCents == first.baselineCents && $0.lastCents == first.lastCents && $0.recharge == first.recharge && ($0.peakCents ?? $0.baselineCents) == (first.peakCents ?? first.baselineCents) }) else { continue }
                    let key = walletKey(identity, unit: unit)
                    if states[key] == nil {
                        var migrated = records.max { ($0.sampleSequence ?? 0) < ($1.sampleSequence ?? 0) }
                        if !records.allSatisfy({ $0.baselineObservedAt == first.baselineObservedAt }) {
                            migrated?.baselineObservedAt = nil
                        }
                        states[key] = migrated
                    }
                }
            } else {
                guard identity.clientID != AssistantClient.codex.rawValue else { continue }
                guard preparedWallets.insert(scope).inserted else { continue }
                let old = peers.compactMap { states[$0.storageKey] }
                guard let first = old.first,
                      old.allSatisfy({ $0.baselineCents == first.baselineCents && $0.lastCents == first.lastCents && $0.unit == first.unit }) else { continue }
                let key = walletKey(identity, unit: first.unit)
                if states[key] == nil {
                    states[key] = State(baselineCents: first.baselineCents, lastCents: first.lastCents, unit: first.unit)
                    changed = true
                }
            }
        }
        if changed {
            persist()
            defaults.set(["scopes": Array(migratedNameScopes), "consumed": Array(consumedLegacyKeys)], forKey: Self.migrationKey)
        }
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
        var next = previous ?? State(baselineCents: cents, lastCents: cents, unit: unit,
            peakCents: cents, baselineObservedAt: observedAt)
        if accepted {
            if let previous, previous.baselineObservedAt == nil {
                // Legacy records without a trustworthy observation date cannot
                // support historical consumption. Rebase on the first accepted
                // sample while preserving an independently observed recharge.
                next = State(baselineCents: cents, lastCents: cents, unit: unit,
                    recharge: previous.recharge, observedAt: observedAt,
                    sampleSequence: sampleSequence, peakCents: cents,
                    baselineObservedAt: observedAt)
            } else if let previous, cents > previous.lastCents {
                next.recharge = BalanceRecharge(amountCents: cents - previous.lastCents, observedAt: observedAt)
                next = State(baselineCents: cents, lastCents: cents, unit: unit, recharge: next.recharge,
                    observedAt: observedAt, sampleSequence: sampleSequence, peakCents: cents, baselineObservedAt: observedAt)
            } else {
                next = State(baselineCents: next.baselineCents, lastCents: cents, unit: unit, recharge: next.recharge,
                    observedAt: observedAt, sampleSequence: sampleSequence,
                    peakCents: next.peakCents ?? next.baselineCents, baselineObservedAt: next.baselineObservedAt)
            }
            states[key] = next
            persist()
        }
        return .success(Observation(amount: Double(next.lastCents) / 100, unit: next.unit,
            progress: percentage(currentCents: next.lastCents, baselineCents: next.peakCents ?? next.baselineCents),
            recharge: next.recharge, observedAt: next.observedAt ?? observedAt, accepted: accepted,
            progressContext: BalanceProgressContext(baselineCents: next.baselineCents, lastCents: next.lastCents,
                peakCents: next.peakCents, baselineObservedAt: next.baselineObservedAt)))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func cents(from amount: Double) -> Int? {
        guard amount.isFinite,
              amount <= Double(Int.max) / 100 else { return nil }
        guard amount >= 0 else { return nil }
        if amount == 0 { return 0 }

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
