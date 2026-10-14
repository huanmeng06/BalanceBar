import AppKit
import Foundation

enum CCSwitchAggregationReadError: Error { case databaseUnavailable }

struct AggregatedProviderEntry {
    enum Role: String { case `default`, member }
    let source: ProviderSummarySource
    let role: Role
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
    /// Only display semantics participate; source credentials remain private to refresh.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.entry.role == rhs.entry.role
            && lhs.entry.source.name == rhs.entry.source.name && lhs.snapshot == rhs.snapshot
            && lhs.account == rhs.account && lhs.status == rhs.status
            && lhs.reason == rhs.reason && lhs.fetchedAt == rhs.fetchedAt
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
                let entries = [AggregatedProviderEntry(source: defaultSource, role: .default)]
                    + ids.dropFirst().compactMap { id -> AggregatedProviderEntry? in
                        guard let source = byID[id], !source.isOfficial else { return nil }
                        return AggregatedProviderEntry(source: source, role: .member)
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
