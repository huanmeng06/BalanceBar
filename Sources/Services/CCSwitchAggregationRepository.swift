import AppKit
import Foundation

enum CCSwitchAggregationReadError: Error { case databaseUnavailable }

struct AggregatedProviderEntry {
    enum Role: String { case `default`, member }
    let source: ProviderSummarySource
    let role: Role
    var displayOrder: Int? = nil
    var providerID: String { source.id }
}

struct AggregationDisplayIdentity: Hashable {
    let providerID: String
    let accountScope: String
    let configurationRevision: String

    var numericScope: String { "codex|\(providerID)|\(accountScope)|\(configurationRevision)" }
}

struct AggregatedProviderDisplay: Equatable {
    enum Status: Equatable { case loading, fresh, stale, unavailable, error }
    let entry: AggregatedProviderEntry
    let identity: AggregationDisplayIdentity
    var snapshot: Snapshot
    var account: OpenAIAccountPresentation?
    var status: Status
    var reason: String?
    var fetchedAt: Date?
    var groupedNotes: [String]? = nil
    var groupedProviderIDs: [String]? = nil
    /// Only display semantics participate; source credentials remain private to refresh.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.entry.role == rhs.entry.role
            && lhs.entry.displayOrder == rhs.entry.displayOrder
            && lhs.entry.source.name == rhs.entry.source.name && lhs.entry.source.notes == rhs.entry.source.notes
            && lhs.snapshot == rhs.snapshot
            && lhs.account == rhs.account && lhs.status == rhs.status
            && lhs.reason == rhs.reason && lhs.fetchedAt == rhs.fetchedAt
            && lhs.groupedNotes == rhs.groupedNotes && lhs.groupedProviderIDs == rhs.groupedProviderIDs
    }
}

/// Menu-only projection. Original Provider records remain available to every
/// identity-sensitive consumer; amounts are selected, never summed.
enum AggregationWalletPresentation {
    static func cards(_ displays: [AggregatedProviderDisplay], partitions: [String: String]? = nil) -> [AggregatedProviderDisplay] {
        var groups: [[AggregatedProviderDisplay]] = []
        var indices: [String: Int] = [:]
        func walletID(_ display: AggregatedProviderDisplay) -> String? {
            guard !display.entry.source.isOfficial else { return nil }
            return ProviderBalanceProgressIdentity.nameScope(client: .codex, name: display.entry.source.name)
        }
        func unit(_ display: AggregatedProviderDisplay) -> String? {
            let value = display.snapshot.unit?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return value?.isEmpty == false ? value : nil
        }
        var currencies: [String: Set<String>] = [:]
        for display in displays {
            if let wallet = walletID(display), let currency = unit(display) { currencies[wallet, default: []].insert(currency) }
        }
        for display in displays {
            guard let wallet = walletID(display) else { groups.append([display]); continue }
            // An unknown/error record can join the single established currency,
            // but must not bridge two different currency accounts.
            let known = currencies[wallet] ?? []
            let currency = unit(display) ?? (known.count == 1 ? known.first! : "unknown")
            let amount = display.snapshot.amount.flatMap { Self.cents($0) }.map(String.init) ?? "unknown"
            let partition = partitions?[display.entry.providerID] ?? amount
            let key = wallet + "|" + currency + "|" + partition
            if let index = indices[key] { groups[index].append(display) }
            else { indices[key] = groups.count; groups.append([display]) }
        }
        let orderedGroups = groups.enumerated().sorted { lhs, rhs in
            let leftOfficial = lhs.element.first?.entry.source.isOfficial == true
            let rightOfficial = rhs.element.first?.entry.source.isOfficial == true
            return leftOfficial == rightOfficial ? lhs.offset < rhs.offset : leftOfficial
        }.map(\.element)
        return orderedGroups.map { members in
            let first = members[0]
            guard let scope = walletID(first) else { return first }
            let valid = members.filter { $0.snapshot.kind == .balance }
            let selected = valid.first(where: { $0.entry.role == .default }) ?? (valid.isEmpty ? members : valid).max {
                let left = $0.fetchedAt ?? .distantPast
                let right = $1.fetchedAt ?? .distantPast
                return left == right ? $0.status != .fresh && $1.status == .fresh : left < right
            } ?? first
            let unit = unit(selected) ?? "unknown"
            let membership = members.map { $0.identity.numericScope }.sorted()
            let memberKey = String(data: (try? JSONEncoder().encode(membership)) ?? Data(), encoding: .utf8) ?? ""
            let wallet = scope + "|" + unit + "|" + memberKey
            let snapshot: Snapshot
            if let amount = selected.snapshot.amount, selected.snapshot.kind == .balance {
                snapshot = .balance(selected.entry.source.name, amount, unit, selected.entry.source.websiteURL ?? selected.entry.source.query?.websiteURL,
                    selected.snapshot.date ?? selected.fetchedAt ?? .distantPast,
                    progressPercentage: selected.snapshot.balanceProgressPercentage ?? ProviderBalanceProgressStore.minimumVisibleProgressPercentage,
                    recharge: selected.snapshot.balanceRecharge, progressContext: selected.snapshot.balanceProgressContext)
            } else { snapshot = selected.snapshot }
            var notes: [String] = []
            let noteMembers = members.enumerated().sorted {
                let left = $0.element.entry.displayOrder ?? $0.offset
                let right = $1.element.entry.displayOrder ?? $1.offset
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
            for member in noteMembers {
                if let note = member.entry.source.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !note.isEmpty, !notes.contains(note) { notes.append(note) }
            }
            let failed = members.filter { $0.status == .stale || $0.status == .error || $0.status == .unavailable }
            let reason = failed.isEmpty ? selected.reason : failed.map {
                ($0.entry.source.notes ?? $0.entry.source.name) + ": " + ($0.reason ?? tr(.keyAggregationUnavailable))
            }.joined(separator: "\n")
            return AggregatedProviderDisplay(entry: AggregatedProviderEntry(source: selected.entry.source,
                role: members.contains { $0.entry.role == .default } ? .default : .member),
                identity: AggregationDisplayIdentity(providerID: "wallet:" + wallet, accountScope: wallet, configurationRevision: wallet),
                snapshot: snapshot, account: nil, status: failed.isEmpty ? selected.status : .stale, reason: reason, fetchedAt: selected.fetchedAt,
                groupedNotes: notes, groupedProviderIDs: members.map { $0.entry.providerID })
        }
    }
    static func cents(_ amount: Double) -> Int? {
        guard amount.isFinite, amount >= 0, amount < Double(Int.max) / 100 else { return nil }
        return NSDecimalNumber(value: amount).multiplying(by: 100).rounding(accordingToBehavior:
            NSDecimalNumberHandler(roundingMode: .plain, scale: 0, raiseOnExactness: false,
                raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)).intValue
    }

}

/// Reliable mismatches split immediately, including during a partial refresh.
/// Merging requires every member to publish two new, fresh aligned rounds.
/// Re-rendering the same values never advances merging evidence.
struct AggregationWalletGrouping {
    private struct Evidence {
        var partitions: [String: String] = [:]
        var sampleDates: [String: Date] = [:]
        var candidate = ""
        var confirmations = 0
    }
    private var evidence: [String: Evidence] = [:]

    mutating func cards(_ displays: [AggregatedProviderDisplay], now: Date = Date()) -> [AggregatedProviderDisplay] {
        let named = displays.filter { !$0.entry.source.isOfficial &&
            ProviderBalanceProgressIdentity.nameScope(client: .codex, name: $0.entry.source.name) != nil }
        let names = Dictionary(grouping: named, by: { $0.entry.source.name })
        var buckets: [String: [AggregatedProviderDisplay]] = [:]
        for (name, peers) in names {
            let units = Set(peers.compactMap { $0.snapshot.unit?.uppercased() })
            for peer in peers {
                let unit = peer.snapshot.unit?.uppercased() ?? (units.count == 1 ? units.first! : "unknown")
                let key = String(data: (try? JSONEncoder().encode([name, unit])) ?? Data(), encoding: .utf8)!
                buckets[key, default: []].append(peer)
            }
        }
        evidence = evidence.filter { buckets[$0.key] != nil }
        var partitions: [String: String] = [:]
        for (key, peers) in buckets {
            var state = evidence[key] ?? Evidence()
            let ids = Set(peers.map { $0.entry.providerID })
            if Set(state.partitions.keys) != ids {
                state.partitions = state.partitions.filter { ids.contains($0.key) }
                let remainingLabels = Set(state.partitions.values)
                for id in ids where state.partitions[id] == nil {
                    if remainingLabels.isEmpty {
                        state.partitions[id] = "initial"
                    } else if remainingLabels.count == 1, let label = remainingLabels.first {
                        state.partitions[id] = label
                    } else {
                        state.partitions[id] = "new:" + id
                    }
                }
                state.confirmations = 0
                state.sampleDates = [:]
            }
            let reliable = peers.filter { peer in
                peer.status == .fresh && peer.snapshot.kind == .balance &&
                peer.snapshot.amount.flatMap(AggregationWalletPresentation.cents) != nil &&
                Self.sampleIsFresh(peer, now: now)
            }
            // Refine existing partitions without requiring an unrelated/failed peer
            // to refresh. Unknown peers keep their own prior label, never bridging
            // two wallets with observed different balances.
            let reliableByPartition = Dictionary(grouping: reliable, by: { state.partitions[$0.entry.providerID]! })
            for members in reliableByPartition.values {
                let amounts = Dictionary(grouping: members, by: { AggregationWalletPresentation.cents($0.snapshot.amount!)! })
                guard amounts.count > 1 else { continue }
                for group in amounts.values {
                    let label = String(data: try! JSONEncoder().encode(group.map { $0.entry.providerID }.sorted()), encoding: .utf8)!
                    for peer in group { state.partitions[peer.entry.providerID] = label }
                }
                state.confirmations = 0
                state.candidate = ""
            }
            let valid = reliable.count == peers.count
            let newRound = valid && peers.count == ids.count && peers.allSatisfy {
                guard let date = $0.fetchedAt else { return false }
                return state.sampleDates[$0.entry.providerID].map { date > $0 } ?? true
            }
            if newRound {
                let groups = Dictionary(grouping: peers, by: { AggregationWalletPresentation.cents($0.snapshot.amount!)! })
                    .values.map { $0.map { $0.entry.providerID }.sorted() }.sorted { $0.lexicographicallyPrecedes($1) }
                let candidate = String(data: try! JSONEncoder().encode(groups), encoding: .utf8)!
                state.confirmations = state.candidate == candidate ? state.confirmations + 1 : 1
                state.candidate = candidate
                state.sampleDates = Dictionary(uniqueKeysWithValues: peers.map { ($0.entry.providerID, $0.fetchedAt!) })
                if state.confirmations >= 2 {
                    for group in groups {
                        let label = String(data: try! JSONEncoder().encode(group), encoding: .utf8)!
                        for id in group { state.partitions[id] = label }
                    }
                }
            }
            evidence[key] = state
            partitions.merge(state.partitions) { _, new in new }
        }
        return AggregationWalletPresentation.cards(displays, partitions: partitions)
    }

    private static func sampleIsFresh(_ display: AggregatedProviderDisplay, now: Date) -> Bool {
        guard let fetched = display.fetchedAt, fetched <= now else { return false }
        let interval = TimeInterval(max(1, display.entry.source.query?.intervalMinutes ?? 1) * 60)
        return now.timeIntervalSince(fetched) <= max(interval, 120)
    }
}

/// CC Switch owns this private device file. Only these fields are decoded;
/// unknown extension fields and credentials never leave the reader.
final class CCSwitchAggregationRepository {
    static let defaultStateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cc-switch/live-state.json")

    enum State {
        case inactive
        case untrusted
        case active([AggregatedProviderEntry])
    }

    private struct DeviceState: Decodable {
        let version: Int?
        let apps: Apps
        struct Apps: Decodable { let codex: Codex? }
        struct Stack: Decodable { let enabled: Bool?; let members: [String]? }
        struct Codex: Decodable, Equatable {
            let mode: String?
            let attached: Bool?
            let proxy_route: String?
            let stack: Stack?
            let pending: Bool
            enum CodingKeys: String, CodingKey { case mode, attached, proxy_route, stack, pending }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                mode = try c.decodeIfPresent(String.self, forKey: .mode)
                attached = try c.decodeIfPresent(Bool.self, forKey: .attached)
                proxy_route = try c.decodeIfPresent(String.self, forKey: .proxy_route)
                stack = try c.decodeIfPresent(Stack.self, forKey: .stack)
                pending = try c.contains(.pending) && !c.decodeNil(forKey: .pending)
            }
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.mode == rhs.mode && lhs.attached == rhs.attached
                    && lhs.proxy_route == rhs.proxy_route && lhs.pending == rhs.pending
                    && lhs.stack?.enabled == rhs.stack?.enabled && lhs.stack?.members == rhs.stack?.members
            }
        }
    }

    static let confirmedAbsenceInterval: TimeInterval = 3

    let stateURL: URL
    private let sources: ([String]) throws -> [ProviderSummarySource]
    private let safety: () -> CCSwitchQuickSwitchSafety
    private let read: (URL) throws -> Data
    private let isRunning: () -> Bool
    private let now: () -> Date
    private let stateLock = NSLock()
    private var wasAggregating = false
    private var quickSwitchProtectionActive = false
    private var absenceBegan: Date?
    private var absenceConfirmed = false
    private func rememberAggregation(_ active: Bool) {
        stateLock.lock()
        wasAggregating = active
        quickSwitchProtectionActive = active
        absenceBegan = nil
        absenceConfirmed = false
        stateLock.unlock()
    }
    private var lastKnownAggregation: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return wasAggregating
    }

    init(repository: CCSwitchRepository,
         stateURL: URL? = nil,
         isRunning: @escaping () -> Bool = {
             !NSRunningApplication.runningApplications(withBundleIdentifier: "com.ccswitch.desktop").isEmpty
         },
         read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
         now: @escaping () -> Date = Date.init) {
        let stateURL = stateURL ?? repository.deviceStateURL
        self.stateURL = stateURL
        self.sources = { try repository.loadSummarySourcesChecked(appType: "codex", providerIDs: $0) }
        self.safety = { repository.quickSwitchSafety(stateURL: stateURL, readState: read) }
        self.read = read
        self.isRunning = isRunning
        self.now = now
    }

    private func deviceState() throws -> DeviceState { try JSONDecoder().decode(DeviceState.self, from: read(stateURL)) }

    func load() -> State {
        for _ in 0..<2 {
            do {
                let before = try deviceState()
                guard before.version == nil || before.version == 1 else { return .untrusted }
                guard let codex = before.apps.codex else { return confirmedAbsenceOrUntrusted() }
                guard !codex.pending, codex.mode == "direct" || codex.mode == "proxy" else { return .untrusted }
                guard codex.mode == "proxy", codex.attached == true,
                      codex.stack?.enabled == true else { rememberAggregation(false); return .inactive }
                guard isRunning(), let route = codex.proxy_route, !route.isEmpty else { return .untrusted }
                var seen: Set<String> = []
                var ids = (codex.stack?.members ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
                if seen.insert(route).inserted { ids.append(route) }
                let rows = try sources(ids)
                let after = try deviceState()
                guard before.version == after.version, codex == after.apps.codex else { continue }
                let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                guard let defaultSource = byID[route] else { return .untrusted }
                let displayOrders = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
                let entries = ids.compactMap { id -> AggregatedProviderEntry? in
                    guard let source = byID[id] else { return nil }
                    if id == route {
                        return AggregatedProviderEntry(source: defaultSource, role: .default, displayOrder: displayOrders[id])
                    }
                    guard !source.isOfficial else { return nil }
                    return AggregatedProviderEntry(source: source, role: .member, displayOrder: displayOrders[id])
                }
                rememberAggregation(true)
                return .active(entries)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return confirmedAbsenceOrUntrusted()
            } catch { return .untrusted }
        }
        return .untrusted
    }

    private func confirmedAbsenceOrUntrusted() -> State {
        let decision = safety()
        stateLock.lock()
        defer { stateLock.unlock() }
        if !decision.isBlocked {
            wasAggregating = false
            quickSwitchProtectionActive = false
            absenceBegan = nil
            absenceConfirmed = false
            return .inactive
        }
        quickSwitchProtectionActive = true
        if absenceConfirmed { return .inactive }
        let current = now()
        if absenceBegan == nil { absenceBegan = current }
        if let started = absenceBegan, current.timeIntervalSince(started) >= Self.confirmedAbsenceInterval {
            absenceConfirmed = true
            absenceBegan = nil
            return .inactive
        }
        return .untrusted
    }

    func quickSwitchSafety() -> CCSwitchQuickSwitchSafety { safety() }

    /// Independently re-read local evidence at every destructive boundary.
    func blocksQuickSwitch() -> Bool { safety().isBlocked }
}
