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
    static func cards(_ displays: [AggregatedProviderDisplay]) -> [AggregatedProviderDisplay] {
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
            let key = wallet + "|" + currency
            if let index = indices[key] { groups[index].append(display) }
            else { indices[key] = groups.count; groups.append([display]) }
        }
        groups = groups.enumerated().sorted { lhs, rhs in
            let leftDefault = lhs.element.contains { $0.entry.role == .default }
            let rightDefault = rhs.element.contains { $0.entry.role == .default }
            return leftDefault == rightDefault ? lhs.offset < rhs.offset : leftDefault
        }.map(\.element)
        return groups.map { members in
            let first = members[0]
            guard let scope = walletID(first) else { return first }
            let valid = members.filter { $0.snapshot.kind == .balance }
            let selected = (valid.isEmpty ? members : valid).max {
                let left = $0.fetchedAt ?? .distantPast
                let right = $1.fetchedAt ?? .distantPast
                return left == right ? $0.status != .fresh && $1.status == .fresh : left < right
            } ?? first
            let unit = unit(selected) ?? "unknown"
            let wallet = scope + "|" + unit
            let snapshot: Snapshot
            if let amount = selected.snapshot.amount, selected.snapshot.kind == .balance {
                snapshot = .balance(first.entry.source.name, amount, unit, first.entry.source.websiteURL ?? first.entry.source.query?.websiteURL,
                    selected.snapshot.date ?? selected.fetchedAt ?? .distantPast,
                    progressPercentage: selected.snapshot.balanceProgressPercentage, recharge: selected.snapshot.balanceRecharge)
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
            return AggregatedProviderDisplay(entry: AggregatedProviderEntry(source: first.entry.source,
                role: members.contains { $0.entry.role == .default } ? .default : .member),
                identity: AggregationDisplayIdentity(providerID: "wallet:" + wallet, accountScope: wallet, configurationRevision: wallet),
                snapshot: snapshot, account: nil, status: selected.status, reason: selected.reason, fetchedAt: selected.fetchedAt,
                groupedNotes: notes, groupedProviderIDs: members.map { $0.entry.providerID })
        }
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

    let stateURL: URL
    private let sources: ([String]) throws -> [ProviderSummarySource]
    private let read: (URL) throws -> Data
    private let isRunning: () -> Bool

    init(repository: CCSwitchRepository,
         stateURL: URL = CCSwitchAggregationRepository.defaultStateURL,
         isRunning: @escaping () -> Bool = {
             !NSRunningApplication.runningApplications(withBundleIdentifier: "com.ccswitch.desktop").isEmpty
         },
         read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.stateURL = stateURL
        self.sources = { try repository.loadSummarySourcesChecked(appType: "codex", providerIDs: $0) }
        self.read = read
        self.isRunning = isRunning
    }

    private func deviceState() throws -> DeviceState { try JSONDecoder().decode(DeviceState.self, from: read(stateURL)) }

    func load() -> State {
        for _ in 0..<2 {
            do {
                let before = try deviceState()
                guard before.version == nil || before.version == 1 else { return .untrusted }
                guard let codex = before.apps.codex else { return .inactive }
                guard !codex.pending, codex.mode == "direct" || codex.mode == "proxy" else { return .untrusted }
                guard codex.mode == "proxy", codex.attached == true,
                      codex.stack?.enabled == true else { return .inactive }
                guard isRunning(), let route = codex.proxy_route, !route.isEmpty else { return .untrusted }
                var seen: Set<String> = [route]
                let ids = [route] + (codex.stack?.members ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
                let rows = try sources(ids)
                let after = try deviceState()
                guard before.version == after.version, codex == after.apps.codex else { continue }
                let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                guard let defaultSource = byID[route] else { return .untrusted }
                let displayOrders = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
                let entries = [AggregatedProviderEntry(source: defaultSource, role: .default, displayOrder: displayOrders[route])]
                    + ids.dropFirst().compactMap { id -> AggregatedProviderEntry? in
                        guard let source = byID[id], !source.isOfficial else { return nil }
                        return AggregatedProviderEntry(source: source, role: .member, displayOrder: displayOrders[id])
                    }
                return .active(entries)
            } catch { return .untrusted }
        }
        return .untrusted
    }

    /// Recheck at the write boundary, even if the menu was built in another mode.
    /// A missing file is compatible with legacy CC Switch; unreadable/corrupt
    /// existing state must never authorize the old stop/write/restart transaction.
    func blocksQuickSwitch() -> Bool {
        do {
            let state = try deviceState()
            guard state.version == nil || state.version == 1 else { return true }
            guard let codex = state.apps.codex else { return false }
            return codex.pending || (codex.mode != "direct" && codex.mode != "proxy")
                || (codex.mode == "proxy" && codex.stack?.enabled == true)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        } catch { return true }
    }
}
